import adapter/alert_hub
import adapter/context.{type Context}
import adapter/hazard_hub
import adapter/response_cache
import domain/alert.{type AlertRow}
import domain/cap
import domain/wis2.{
  type BrokerState, type ChannelHealth, type Wis2CapFeature,
  type Wis2HealthFeature, type Wis2PollMeta, type Wis2TcFeature,
}
import domain/wis2_matcher
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp
import message/reciever/models/cap as models_cap
import repository/alert_writer.{AlertDiff}
import repository/cap_message_writer.{CapItemPayload}
import repository/wis2_writer

pub type Wis2Ack {
  Wis2Ack(
    received: Int,
    written: Int,
    deduped: Int,
    dropped: Int,
    message: String,
  )
}

pub fn process_cap(
  _meta: Option(Wis2PollMeta),
  features: List(Wis2CapFeature),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(Wis2Ack, String) {
  let now = timestamp.system_time()
  let initial_acc = #(0, 0, decode_dropped, [])

  use #(written, deduped, dropped, all_diffs) <- result.try(
    list.try_fold(features, initial_acc, fn(acc, feature) {
      let #(w_acc, d_acc, dr_acc, diffs_acc) = acc
      let pubtime = cap.parse_rfc3339(feature.pubtime) |> option.from_result
      let download_url = feature.download_url
      let cap_url = case download_url {
        Some(u) if u != "" -> u
        _ -> "inline:" <> feature.data_id
      }
      let feed_url = feature.topic
      let kind = "warnings"

      case feature.cap {
        None -> {
          let _ =
            wis2_writer.record_notification(
              feature.data_id,
              feature.notification_id,
              feature.centre_id,
              kind,
              feature.topic,
              feature.channel,
              pubtime,
              now,
              feature.fetched_via,
              download_url,
              None,
              None,
              "dropped",
              ctx.db,
            )
          Ok(#(w_acc, d_acc, dr_acc + 1, diffs_acc))
        }

        Some(msg) -> {
          let src = wis2.make_source(feature.centre_id, feature.license_url)
          use _ <- result.try(wis2_writer.upsert_source(src, ctx.db))

          let is_new_area = case feature.area_key, feature.area_geometry {
            Some(key), Some(geom) if key != "" && geom != "" -> {
              let precision = option.unwrap(feature.area_precision, wis2.Exact)
              case
                wis2_writer.upsert_area(
                  msg.sender,
                  msg.identifier,
                  key,
                  geom,
                  precision,
                  now,
                  ctx.db,
                )
              {
                Ok(outcome) -> wis2_writer.is_new_area_outcome(outcome)
                Error(_) -> False
              }
            }
            _, _ -> False
          }

          let fetch_result =
            models_cap.CapFetchResult(
              cap_url:,
              feed_url:,
              fetched_at: feature.pubtime,
              http_status: 200,
              error: None,
              cap: Some(msg),
              raw_cap_json: Some(msg.raw_json),
              raw_xml: Some(feature.raw_xml),
            )
          let payload =
            CapItemPayload(
              result: fetch_result,
              msg: msg,
              owner_source_id: src.id,
              country_iso3: "",
            )

          use inc_rec <- result.try(
            cap.make_incoming_record(msg, payload)
            |> result.map_error(fn(e) { "CAP record creation failed: " <> e }),
          )

          use outcome <- result.try(
            cap_message_writer.write_batch([inc_rec], now, ctx.db)
            |> result.map_error(fn(e) { "CAP message write failed: " <> e }),
          )

          let cap_has_own_geom = wis2_writer.has_cap_geometry(msg)
          let is_new = outcome.new > 0
          let is_updated = outcome.updated > 0
          let is_written = is_new || is_updated || is_new_area
          let #(feature_written, feature_deduped) = case is_written {
            True -> #(1, 0)
            False -> #(0, 1)
          }

          let batch_diff = outcome.result.diff
          let diff = case !cap_has_own_geom && is_written {
            True ->
              case
                wis2_writer.update_alert_geometry_from_areas(
                  msg.sender,
                  msg.identifier,
                  ctx.db,
                )
              {
                Ok(updated_alerts) ->
                  case is_new {
                    True ->
                      AlertDiff(
                        new: merge_alert_rows(batch_diff.new, updated_alerts),
                        updated: batch_diff.updated,
                        ended: batch_diff.ended,
                      )
                    False ->
                      AlertDiff(
                        new: batch_diff.new,
                        updated: merge_alert_rows(
                          batch_diff.updated,
                          updated_alerts,
                        ),
                        ended: batch_diff.ended,
                      )
                  }
                Error(_) -> batch_diff
              }
            False -> batch_diff
          }

          let outcome_str = case is_written {
            True -> "written"
            False -> "deduped"
          }

          let _ =
            wis2_writer.record_notification(
              feature.data_id,
              feature.notification_id,
              feature.centre_id,
              kind,
              feature.topic,
              feature.channel,
              pubtime,
              now,
              feature.fetched_via,
              download_url,
              Some(msg.sender),
              Some(msg.identifier),
              outcome_str,
              ctx.db,
            )

          Ok(
            #(w_acc + feature_written, d_acc + feature_deduped, dr_acc, [
              diff,
              ..diffs_acc
            ]),
          )
        }
      }
    }),
  )

  let combined_diff =
    AlertDiff(
      new: list.flat_map(all_diffs, fn(d) { d.new }),
      updated: list.flat_map(all_diffs, fn(d) { d.updated }),
      ended: list.flat_map(all_diffs, fn(d) { d.ended }),
    )

  case
    list.is_empty(combined_diff.new)
    && list.is_empty(combined_diff.updated)
    && list.is_empty(combined_diff.ended)
  {
    True -> Nil
    False -> {
      alert_hub.publish(ctx.hub, combined_diff)
      response_cache.invalidate(ctx.alert_cache)
    }
  }

  alert_hub.record_source(
    ctx.hub,
    "wis2",
    alert_hub.SourceWrite(
      http_status: 200,
      received: received,
      written: written,
      dropped: dropped,
      bytes: 0,
      dedup_intake: 0,
      dedup_unchanged: deduped,
      dedup_stale: 0,
      matched: 0,
    ),
  )

  Ok(Wis2Ack(
    received: received,
    written: written,
    deduped: deduped,
    dropped: dropped,
    message: int.to_string(written) <> " messages written",
  ))
}

pub fn process_health(
  meta: Option(Wis2PollMeta),
  features: List(Wis2HealthFeature),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(Wis2Ack, String) {
  let now = timestamp.system_time()
  let broker_url = option.then(meta, fn(m) { m.feed_url }) |> option.unwrap("")
  let broker_err = option.then(meta, fn(m) { m.error })
  let connected = case broker_err {
    Some(e) if e != "" -> False
    _ -> True
  }

  use _ <- result.try(wis2_writer.write_broker(
    broker_url,
    connected,
    broker_err,
    now,
    ctx.db,
  ))

  use _ <- result.try(
    list.try_each(features, fn(feature) {
      let bucket_start =
        cap.parse_rfc3339(feature.window_start)
        |> result.unwrap(now)
        |> wis2.truncate_to_hour
      let last_received_at =
        option.then(feature.last_received_at, fn(s) {
          option.from_result(cap.parse_rfc3339(s))
        })
      wis2_writer.write_health_bucket(
        feature.centre_id,
        feature.kind,
        bucket_start,
        feature.received,
        feature.duplicates,
        feature.download_failed,
        feature.decode_failed,
        feature.integrity_failed,
        last_received_at,
        ctx.db,
      )
    }),
  )

  let written = list.length(features)
  Ok(Wis2Ack(
    received: received,
    written: written,
    deduped: 0,
    dropped: decode_dropped,
    message: int.to_string(written) <> " health reports written",
  ))
}

pub fn get_health(
  ctx: Context,
) -> Result(#(BrokerState, List(ChannelHealth)), String) {
  let now = timestamp.system_time()
  wis2_writer.read_health_summary(now, ctx.db)
}

fn merge_alert_rows(
  alerts: List(AlertRow),
  targets: List(AlertRow),
) -> List(AlertRow) {
  list.fold(targets, alerts, replace_or_append_alert)
}

fn replace_or_append_alert(
  alerts: List(AlertRow),
  target: AlertRow,
) -> List(AlertRow) {
  let #(replaced, found) =
    list.fold(alerts, #([], False), fn(acc, a) {
      let #(res, f) = acc
      case a.source == target.source && a.source_id == target.source_id {
        True -> #([target, ..res], True)
        False -> #([a, ..res], f)
      }
    })
  case found {
    True -> list.reverse(replaced)
    False -> [target, ..alerts]
  }
}

pub fn process_tc_tracks(
  _meta: Option(Wis2PollMeta),
  features: List(Wis2TcFeature),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(Wis2Ack, String) {
  let now = timestamp.system_time()
  let now_ms = timestamp_to_ms(now)

  use candidates <- result.try(wis2_writer.load_active_gdacs_tc_hazards(ctx.db))

  let initial_acc = #(0, 0, decode_dropped, [], [])
  use #(written, deduped, dropped, new_hazards, updated_hazards) <- result.try(
    list.try_fold(features, initial_acc, fn(acc, feature) {
      let #(w_acc, d_acc, dr_acc, new_h_acc, upd_h_acc) = acc
      let source = "wis2-" <> feature.centre_id

      case cap.parse_rfc3339(feature.analysis_time) {
        Error(_) -> Ok(#(w_acc, d_acc, dr_acc + 1, new_h_acc, upd_h_acc))
        Ok(analysis_ts) -> {
          let analysis_time_ms = timestamp_to_ms(analysis_ts)

          use _ <- result.try(wis2_writer.upsert_tc_source(
            feature.centre_id,
            ctx.db,
          ))
          use exists <- result.try(wis2_writer.track_exists(
            source,
            feature.storm_id,
            analysis_ts,
            ctx.db,
          ))

          case exists {
            True -> Ok(#(w_acc, d_acc + 1, dr_acc, new_h_acc, upd_h_acc))
            False -> {
              let #(analysis_lon, analysis_lat) =
                wis2.points_to_centroid(feature.points)
              let maybe_match =
                wis2_matcher.match_tc_run(
                  feature.storm_id,
                  feature.storm_name,
                  analysis_time_ms,
                  analysis_lat,
                  analysis_lon,
                  candidates,
                )

              case maybe_match {
                Some(gdacs_hazard) -> {
                  use _ <- result.try(wis2_writer.write_tc_track(
                    feature,
                    source,
                    analysis_ts,
                    Some("gdacs"),
                    Some(gdacs_hazard.source_id),
                    now,
                    ctx.db,
                  ))
                  use _ <- result.try(wis2_writer.link_older_tracks_to_hazard(
                    source,
                    feature.storm_id,
                    "gdacs",
                    gdacs_hazard.source_id,
                    ctx.db,
                  ))
                  use ended_hazards <- result.try(
                    wis2_writer.end_own_tc_hazards_for_storm(
                      source,
                      feature.storm_id,
                      now_ms,
                      ctx.db,
                    ),
                  )

                  let upd = [
                    gdacs_hazard,
                    ..list.append(ended_hazards, upd_h_acc)
                  ]
                  Ok(#(w_acc + 1, d_acc, dr_acc, new_h_acc, upd))
                }

                None -> {
                  case
                    wis2_matcher.is_named(feature.storm_id, feature.storm_name)
                  {
                    True -> {
                      let own_source_id =
                        wis2.tc_hazard_source_id(
                          feature.storm_id,
                          feature.analysis_time,
                        )
                      use _ <- result.try(wis2_writer.write_tc_track(
                        feature,
                        source,
                        analysis_ts,
                        Some(source),
                        Some(own_source_id),
                        now,
                        ctx.db,
                      ))
                      use #(h, is_new) <- result.try(
                        wis2_writer.upsert_own_tc_hazard(
                          feature,
                          source,
                          analysis_time_ms,
                          now,
                          ctx.db,
                        ),
                      )
                      case is_new {
                        True ->
                          Ok(#(
                            w_acc + 1,
                            d_acc,
                            dr_acc,
                            [h, ..new_h_acc],
                            upd_h_acc,
                          ))
                        False ->
                          Ok(
                            #(w_acc + 1, d_acc, dr_acc, new_h_acc, [
                              h,
                              ..upd_h_acc
                            ]),
                          )
                      }
                    }

                    False -> {
                      use _ <- result.try(wis2_writer.write_tc_track(
                        feature,
                        source,
                        analysis_ts,
                        None,
                        None,
                        now,
                        ctx.db,
                      ))
                      Ok(#(w_acc + 1, d_acc, dr_acc, new_h_acc, upd_h_acc))
                    }
                  }
                }
              }
            }
          }
        }
      }
    }),
  )

  let unique_new = list.unique(new_hazards)
  let unique_updated = list.unique(updated_hazards)

  case !list.is_empty(unique_new) || !list.is_empty(unique_updated) {
    True -> {
      hazard_hub.publish(ctx.hazard_hub, unique_new, unique_updated)
      response_cache.invalidate(ctx.hazard_cache)
    }
    False -> Nil
  }

  Ok(Wis2Ack(
    received:,
    written:,
    deduped:,
    dropped:,
    message: int.to_string(written) <> " TC tracks written",
  ))
}

fn timestamp_to_ms(ts: timestamp.Timestamp) -> Int {
  let #(sec, nano) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  sec * 1000 + nano / 1_000_000
}

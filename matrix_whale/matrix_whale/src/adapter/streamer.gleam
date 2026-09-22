import adapter/alert_hub.{type HubMsg, type SSEMessage, Emit, Heartbeat, Resync}
import adapter/compression
import adapter/context.{type Context}
import adapter/earthquake_hub
import adapter/hazard_hub
import adapter/live_stream
import adapter/response_cache
import domain/alert
import domain/cap_feed_view
import domain/earthquake
import domain/event
import domain/hazard
import domain/source
import domain/timeline
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/time/calendar
import gleam/time/timestamp
import metrics
import mist
import repository/alert_reader
import repository/cap_feed_reader
import repository/earthquake_reader
import repository/hazard_reader
import repository/source_writer
import repository/timeline_reader
import wisp

type SSEState {
  SSEState(subscriber_id: Int, hub: Subject(HubMsg), sent_retry: Bool)
}

type EarthquakeSSEState {
  EarthquakeSSEState(
    id: Int,
    hub: Subject(earthquake_hub.EarthquakeHubMsg),
    sent_retry: Bool,
  )
}

type HazardSSEState {
  HazardSSEState(
    id: Int,
    hub: Subject(hazard_hub.HazardHubMsg),
    sent_retry: Bool,
  )
}

pub fn streamer(ctx: Context) {
  wisp.log_info("Starting alert streamer")

  let assert Ok(_) =
    fn(req) { router(req, ctx) }
    |> mist.new
    |> mist.port(8080)
    |> mist.bind("0.0.0.0")
    |> mist.start()

  wisp.log_info("Alert streamer started")
  process.sleep_forever()
}

fn router(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let start = metrics.monotonic_now()
  let segments = request.path_segments(req)
  let route = metrics.route_template(segments)
  let method = http.method_to_string(req.method)

  let res = case segments {
    ["api", "v1", "streamer", "health"] -> health_response()
    ["api", "v1", "alerts", "active"] -> active_response(req, ctx)
    ["api", "v1", "alerts", "detail"] -> alert_detail_response(req, ctx)
    ["api", "v1", "alerts", "stream"] -> stream_response(req, ctx)
    ["api", "v1", "alerts", "search"] -> search_response(req, ctx)
    ["api", "v1", "alerts", "history"] -> history_response(req, ctx)
    ["api", "v1", "cap", "feeds"] -> cap_feeds_response(req, ctx)
    ["api", "v1", "earthquakes", "recent"] -> earthquakes_response(req, ctx)
    ["api", "v1", "earthquakes", "stream"] ->
      case req.method {
        http.Get -> earthquake_stream_response(req, ctx)
        _ ->
          response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    ["api", "v1", "pipeline", "status"] -> pipeline_status_response(ctx)
    ["api", "v1", "sources"] -> sources_response(ctx)
    ["api", "v1", "hazards", "recent"] -> hazards_response(req, ctx)
    ["api", "v1", "hazards", "stream"] ->
      case req.method {
        http.Get -> hazard_stream_response(req, ctx)
        _ ->
          response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    ["api", "v1", "hazards", hazard_source, hazard_source_id] ->
      hazard_detail_response(hazard_source, hazard_source_id, ctx)
    ["api", "v1", "timeline"] -> timeline_response(req, ctx)
    ["api", "v1", "stream"] ->
      case req.method {
        http.Get -> live_stream.response(req, ctx)
        _ ->
          response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    _ -> not_found_response()
  }

  let res = compression.compress_response_if_needed(req, res)

  let duration = metrics.monotonic_elapsed_seconds(start)
  metrics.observe_http(metrics.Api, route, method, res.status, duration)
  res
}

fn earthquake_stream_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> earthquake_stream_response_actual(req, ctx)
    _ -> response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn earthquake_stream_response_actual(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let since = request.get_header(req, "last-event-id") |> option.from_result
  mist.server_sent_events(
    req,
    response.new(200),
    init: fn(subject) {
      EarthquakeSSEState(
        id: earthquake_hub.subscribe(ctx.earthquake_hub, subject, since),
        hub: ctx.earthquake_hub,
        sent_retry: False,
      )
    },
    loop: fn(
      state: EarthquakeSSEState,
      message: earthquake_hub.SSEMessage,
      conn: mist.SSEConnection,
    ) -> actor.Next(EarthquakeSSEState, earthquake_hub.SSEMessage) {
      let event = case message {
        earthquake_hub.Emit(name, id, data) ->
          mist.event(string_tree.from_string(data))
          |> mist.event_name(name)
          |> mist.event_id(id)
        earthquake_hub.Heartbeat(id) ->
          mist.event(string_tree.from_string("{}"))
          |> mist.event_name("heartbeat")
          |> mist.event_id(id)
        earthquake_hub.Resync(id) ->
          mist.event(string_tree.from_string("{\"reason\":\"event_gap\"}"))
          |> mist.event_name("resync")
          |> mist.event_id(id)
      }
      let event = case state.sent_retry {
        True -> event
        False -> mist.event_retry(event, 3000)
      }
      case mist.send_event(conn, event) {
        Ok(_) -> actor.continue(EarthquakeSSEState(..state, sent_retry: True))
        Error(_) -> {
          earthquake_hub.unsubscribe(state.hub, state.id)
          actor.stop()
        }
      }
    },
  )
}

pub fn earthquakes_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> earthquakes_get_response(req, ctx)
    _ -> response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn earthquakes_get_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let hours = case list.key_find(query, "hours") {
    Ok(value) ->
      int.parse(value)
      |> result.map_error(fn(_) { "hours must be an integer 1..168" })
    Error(_) -> Ok(24)
  }
  case hours {
    Error(error) ->
      json_response(400, json.object([#("error", json.string(error))]))
    Ok(hours) ->
      case
        earthquake.parse_minmag(
          query |> list.key_find("minmag") |> result.unwrap(""),
        )
      {
        Error(error) ->
          json_response(400, json.object([#("error", json.string(error))]))
        Ok(minmag) ->
          case
            parse_type(
              query |> list.key_find("type") |> result.unwrap("earthquake"),
            )
          {
            Error(error) ->
              json_response(400, json.object([#("error", json.string(error))]))
            Ok(type_) ->
              case hours < 1 || hours > 168 {
                True ->
                  json_response(
                    400,
                    json.object([
                      #("error", json.string("hours must be 1..168")),
                    ]),
                  )
                False ->
                  case earthquake_reader.recent(hours, minmag, type_, ctx.db) {
                    Error(error) -> error_response(error)
                    Ok(rows) ->
                      etag_json_response(
                        req,
                        json.object([
                          #("earthquakes", json.array(rows, event.to_json)),
                        ]),
                      )
                  }
              }
          }
      }
  }
}

pub fn parse_type(
  value: String,
) -> Result(earthquake_reader.TypeFilter, String) {
  case value {
    "earthquake" -> Ok(earthquake_reader.EarthquakesOnly)
    "all" -> Ok(earthquake_reader.AllTypes)
    _ -> Error("type must be earthquake or all")
  }
}

pub fn etag_json_response(
  req: Request(connection),
  body: json.Json,
) -> Response(mist.ResponseData) {
  let text = json.to_string(body)
  tagged_json_response(req, text, text, "")
}

fn cached_json_response(
  req: Request(connection),
  cache: Subject(response_cache.CacheMsg),
  weakness: String,
  build: fn() -> Result(#(String, String), String),
) -> Response(mist.ResponseData) {
  let key = cache_key(req)
  let #(cached, generation) = response_cache.get(cache, key)
  case cached {
    option.Some(entry) -> entry_response(req, entry)
    option.None ->
      case build() {
        Error(message) -> error_response(message)
        Ok(#(text, validator_text)) -> {
          let entry =
            response_cache.CacheEntry(
              etag: weakness <> "\"" <> sha256_hex(validator_text) <> "\"",
              body: text,
              gzip: compression.gzip(bit_array.from_string(text)),
            )
          response_cache.put(cache, key, generation, entry)
          entry_response(req, entry)
        }
      }
  }
}

fn cache_key(req: Request(connection)) -> String {
  let query =
    request.get_query(req)
    |> result.unwrap([])
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
    |> string.join("&")
  case query {
    "" -> req.path
    _ -> req.path <> "?" <> query
  }
}

fn entry_response(
  req: Request(connection),
  entry: response_cache.CacheEntry,
) -> Response(mist.ResponseData) {
  let gzip = case compression.request_accepts_gzip(req) {
    True -> option.Some(entry.gzip)
    False -> option.None
  }
  tagged_response(req, entry.etag, entry.body, gzip)
}

fn tagged_json_response(
  req: Request(connection),
  text: String,
  validator_text: String,
  weakness: String,
) -> Response(mist.ResponseData) {
  let base_etag = weakness <> "\"" <> sha256_hex(validator_text) <> "\""
  let gzip = case compression.request_accepts_gzip(req) {
    True -> option.Some(compression.gzip(bit_array.from_string(text)))
    False -> option.None
  }
  tagged_response(req, base_etag, text, gzip)
}

fn tagged_response(
  req: Request(connection),
  base_etag: String,
  text: String,
  gzip: option.Option(BitArray),
) -> Response(mist.ResponseData) {
  let response_etag = case gzip {
    option.Some(_) -> string.drop_end(base_etag, 1) <> "-gzip\""
    option.None -> base_etag
  }
  let not_modified = case request.get_header(req, "if-none-match") {
    Ok(value) -> if_none_match_matches(value, response_etag)
    Error(Nil) -> False
  }
  case not_modified {
    True ->
      response.new(304)
      |> response.set_header("etag", response_etag)
      |> response.set_header("cache-control", "no-cache")
      |> compression.add_vary_accept_encoding
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    False -> {
      let res =
        response.new(200)
        |> response.set_header("content-type", "application/json")
        |> response.set_header("etag", response_etag)
        |> response.set_header("cache-control", "no-cache")
        |> compression.add_vary_accept_encoding
      case gzip {
        option.Some(compressed) ->
          res
          |> response.set_header("content-encoding", "gzip")
          |> response.set_header(
            "content-length",
            int.to_string(bit_array.byte_size(compressed)),
          )
          |> response.set_body(
            mist.Bytes(bytes_tree.from_bit_array(compressed)),
          )
        option.None ->
          res |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
      }
    }
  }
}

fn sha256_hex(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bit_array.base16_encode
}

pub fn if_none_match_matches(value: String, etag: String) -> Bool {
  compression.if_none_match_matches(value, etag)
}

pub fn active_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let min_severity_param =
    query |> list.key_find("min_severity") |> result.unwrap("")
  case parse_alert_min_severity(min_severity_param) {
    Error(error) ->
      json_response(400, json.object([#("error", json.string(error))]))
    Ok(severities) -> {
      let sources =
        query |> list.key_find("sources") |> result.unwrap("") |> comma_list
      let countries =
        query |> list.key_find("countries") |> result.unwrap("") |> comma_list
      cached_json_response(req, ctx.alert_cache, "", fn() {
        alert_reader.list_active(sources, countries, severities, ctx.db)
        |> result.map(fn(rows) {
          let text = json.to_string(json.array(rows, alert.to_json))
          #(text, text)
        })
      })
    }
  }
}

fn parse_alert_min_severity(value: String) -> Result(List(String), String) {
  case string.lowercase(string.trim(value)) {
    "" -> Ok([])
    "minor" -> Ok(["Minor", "Moderate", "Severe", "Extreme"])
    "moderate" -> Ok(["Moderate", "Severe", "Extreme"])
    "severe" -> Ok(["Severe", "Extreme"])
    "extreme" -> Ok(["Extreme"])
    _ -> Error("min_severity must be minor, moderate, severe, or extreme")
  }
}

pub fn alert_detail_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  case list.key_find(query, "id") {
    Error(_) ->
      json_response(
        404,
        json.object([#("error", json.string("alert not found"))]),
      )
    Ok(raw_id) ->
      case string.split_once(raw_id, ":") {
        Error(Nil) ->
          json_response(
            404,
            json.object([#("error", json.string("alert not found"))]),
          )
        Ok(#(source, source_id)) ->
          case alert_reader.detail(source, source_id, ctx.db) {
            Error(error) -> error_response(error)
            Ok(option.None) ->
              json_response(
                404,
                json.object([#("error", json.string("alert not found"))]),
              )
            Ok(option.Some(#(row, infos, cap_url, feed_url))) ->
              etag_json_response(
                req,
                alert.to_detail_json(row, infos, cap_url, feed_url),
              )
          }
      }
  }
}

fn search_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query =
    request.get_query(req)
    |> result.unwrap([])
    |> list.key_find("q")
    |> result.unwrap("")

  case alert_reader.search(query, ctx.db) {
    Ok(rows) -> json_response(200, json.array(rows, alert.to_json))
    Error(err) -> error_response(err)
  }
}

fn history_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let hours =
    request.get_query(req)
    |> result.unwrap([])
    |> list.key_find("hours")
    |> result.try(int.parse)
    |> result.unwrap(24)

  case alert_reader.history(hours, ctx.db) {
    Ok(buckets) ->
      json_response(
        200,
        json.array(buckets, alert_reader.history_bucket_to_json),
      )
    Error(err) -> error_response(err)
  }
}

fn pipeline_status_response(ctx: Context) -> Response(mist.ResponseData) {
  let stats = alert_hub.get_stats(ctx.hub)

  case alert_reader.count_active_by_severity(ctx.db) {
    Ok(active_by_severity) ->
      json_response(
        200,
        json.object([
          #("last_fetch_at", json.nullable(stats.last_fetch_at, json.string)),
          #("last_http_status", json.nullable(stats.last_http_status, json.int)),
          #("last_received", json.int(stats.last_received)),
          #("last_decoded", json.int(stats.last_decoded)),
          #("last_dropped", json.int(stats.last_dropped)),
          #("last_write_at", json.nullable(stats.last_write_at, json.string)),
          #("last_new", json.int(stats.last_new)),
          #("last_updated", json.int(stats.last_updated)),
          #("last_ended", json.int(stats.last_ended)),
          #("sse_clients", json.int(stats.sse_clients)),
          #("sources", alert_hub.source_stats_to_json(stats.source_stats)),
          #(
            "active_by_severity",
            alert_reader.severity_counts_to_json(active_by_severity),
          ),
        ]),
      )
    Error(err) -> error_response(err)
  }
}

fn sources_response(ctx: Context) -> Response(mist.ResponseData) {
  case source_writer.list_all(ctx.db) {
    Ok(sources) ->
      json_response(
        200,
        json.object([
          #("sources", json.array(sources, source.to_json)),
        ]),
      )
    Error(err) -> error_response(err)
  }
}

fn cap_feeds_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> {
      let now = timestamp.system_time()
      case cap_feed_reader.view(now, ctx.db) {
        Ok(feeds_view) ->
          etag_json_response(req, cap_feed_view.to_json(feeds_view))
        Error(err) -> error_response(err)
      }
    }
    _ -> response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn hazards_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> hazards_get_response(req, ctx)
    _ -> response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn hazards_get_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let hours =
    query
    |> list.key_find("hours")
    |> result.try(int.parse)
    |> result.unwrap(336)
  let types = query |> list.key_find("types") |> result.unwrap("") |> comma_list
  let levels =
    query |> list.key_find("levels") |> result.unwrap("") |> comma_list

  cached_json_response(req, ctx.hazard_cache, "W/", fn() {
    hazard_reader.recent(hours, types, levels, ctx.db)
    |> result.map(fn(rows) { hazard_snapshot_texts(query, rows, now_rfc3339()) })
  })
}

/// Collection contents determine freshness; the response generation clock is
/// metadata. A weak validator permits revalidation without pretending that
/// responses with different generated_at values are byte-for-byte identical.
pub fn hazard_snapshot_response(
  req: Request(connection),
  rows: List(hazard.Hazard),
  generated_at: String,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let #(text, validator) = hazard_snapshot_texts(query, rows, generated_at)
  tagged_json_response(req, text, validator, "W/")
}

fn hazard_snapshot_texts(
  query: List(#(String, String)),
  rows: List(hazard.Hazard),
  generated_at: String,
) -> #(String, String) {
  let serializer = case list.key_find(query, "geometry") {
    Ok("polyline") -> hazard.to_polyline_json
    _ -> hazard.to_json
  }
  let fields = [
    #("hazards", json.array(rows, serializer)),
    #("count", json.int(list.length(rows))),
  ]
  let validator = json.object(fields) |> json.to_string
  let text =
    json.object([#("generated_at", json.string(generated_at)), ..fields])
    |> json.to_string
  #(text, validator)
}

fn comma_list(value: String) -> List(String) {
  case value {
    "" -> []
    _ ->
      string.split(value, ",")
      |> list.map(string.trim)
      |> list.filter(fn(x) { x != "" })
  }
}

fn now_rfc3339() -> String {
  timestamp.system_time() |> timestamp.to_rfc3339(calendar.utc_offset)
}

fn hazard_detail_response(
  hazard_source: String,
  hazard_source_id: String,
  ctx: Context,
) -> Response(mist.ResponseData) {
  case hazard_reader.detail(hazard_source, hazard_source_id, ctx.db) {
    Error(error) -> error_response(error)
    Ok(option.None) ->
      json_response(
        404,
        json.object([#("error", json.string("hazard not found"))]),
      )
    Ok(option.Some(#(row, episodes))) ->
      json_response(
        200,
        json.object([
          #("hazard", hazard.to_detail_json(row)),
          #("episodes", json.array(episodes, hazard.episode_to_json)),
        ]),
      )
  }
}

pub fn timeline_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> timeline_get_response(req, ctx)
    _ -> response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn timeline_get_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  case timeline.parse_query(query) {
    Error(error) ->
      json_response(400, json.object([#("error", json.string(error))]))
    Ok(parsed) ->
      case timeline_reader.page(parsed, ctx.db) {
        Error(error) -> error_response(error)
        Ok(page) ->
          etag_json_response(
            req,
            json.object([
              #("items", json.array(page.items, timeline.to_json)),
              #("next_cursor", json.nullable(page.next_cursor, json.string)),
              #("generated_at", json.string(now_rfc3339())),
            ]),
          )
      }
  }
}

fn hazard_stream_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let since = request.get_header(req, "last-event-id") |> option.from_result
  mist.server_sent_events(
    req,
    response.new(200),
    init: fn(subject) {
      HazardSSEState(
        id: hazard_hub.subscribe(ctx.hazard_hub, subject, since),
        hub: ctx.hazard_hub,
        sent_retry: False,
      )
    },
    loop: fn(
      state: HazardSSEState,
      message: hazard_hub.SSEMessage,
      conn: mist.SSEConnection,
    ) -> actor.Next(HazardSSEState, hazard_hub.SSEMessage) {
      let event = case message {
        hazard_hub.Emit(name, id, data) ->
          mist.event(string_tree.from_string(data))
          |> mist.event_name(name)
          |> mist.event_id(id)
        hazard_hub.Heartbeat(id) ->
          mist.event(string_tree.from_string("{}"))
          |> mist.event_name("heartbeat")
          |> mist.event_id(id)
        hazard_hub.Resync(id) ->
          mist.event(string_tree.from_string("{\"reason\":\"event_gap\"}"))
          |> mist.event_name("resync")
          |> mist.event_id(id)
      }
      let event = case state.sent_retry {
        True -> event
        False -> mist.event_retry(event, 3000)
      }
      case mist.send_event(conn, event) {
        Ok(_) -> actor.continue(HazardSSEState(..state, sent_retry: True))
        Error(_) -> {
          hazard_hub.unsubscribe(state.hub, state.id)
          actor.stop()
        }
      }
    },
  )
}

fn stream_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let since_id =
    request.get_header(req, "last-event-id")
    |> result.try(int.parse)
    |> option.from_result

  mist.server_sent_events(
    req,
    response.new(200),
    init: fn(subj) {
      let subscriber_id = alert_hub.subscribe(ctx.hub, subj, since_id)
      SSEState(subscriber_id: subscriber_id, hub: ctx.hub, sent_retry: False)
    },
    loop: fn(state: SSEState, message: SSEMessage, conn: mist.SSEConnection) -> actor.Next(
      SSEState,
      SSEMessage,
    ) {
      let event = case message {
        Emit(event_name, id, data) ->
          mist.event(string_tree.from_string(data))
          |> mist.event_name(event_name)
          |> mist.event_id(int.to_string(id))
        Heartbeat(last_id) ->
          mist.event(string_tree.from_string("{}"))
          |> mist.event_name("heartbeat")
          |> mist.event_id(int.to_string(last_id))
        Resync(last_id) ->
          mist.event(string_tree.from_string("{\"reason\":\"event_gap\"}"))
          |> mist.event_name("resync")
          |> mist.event_id(int.to_string(last_id))
      }

      case send_event(conn, state, event) {
        Ok(new_state) -> actor.continue(new_state)
        Error(_) -> {
          alert_hub.unsubscribe(state.hub, state.subscriber_id)
          actor.stop()
        }
      }
    },
  )
}

fn send_event(
  conn: mist.SSEConnection,
  state: SSEState,
  event: mist.SSEEvent,
) -> Result(SSEState, Nil) {
  let event = case state.sent_retry {
    True -> event
    False -> mist.event_retry(event, 3000)
  }

  mist.send_event(conn, event)
  |> result.map(fn(_) { SSEState(..state, sent_retry: True) })
}

fn health_response() -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("system is alive")))
}

fn not_found_response() -> Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn error_response(message: String) -> Response(mist.ResponseData) {
  wisp.log_error(message)
  json_response(500, json.object([#("error", json.string(message))]))
}

fn json_response(status: Int, body: json.Json) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

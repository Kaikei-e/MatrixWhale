import domain/alert.{type AlertRow}
import domain/cap
import domain/hazard.{type Hazard}
import domain/source.{type Source}
import domain/wis2.{
  type AreaPrecision, type BrokerState, type ChannelHealth, type ForecastTrack,
  type Wis2TcFeature, BrokerState, ChannelHealth, ForecastTrack,
}
import domain/wis2_observation.{type StationNeighbour, StationNeighbour}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/cap as models_cap
import pog

pub fn has_cap_geometry(msg: models_cap.CapMessage) -> Bool {
  list.any(msg.info, fn(i) {
    list.any(i.area, fn(a) {
      !list.is_empty(a.polygon) || !list.is_empty(a.circle)
    })
  })
}

pub fn record_notification(
  data_id: String,
  notification_id: String,
  centre_id: String,
  kind: String,
  topic: String,
  channel: String,
  pubtime: Option(Timestamp),
  received_at: Timestamp,
  fetched_via: String,
  download_url: Option(String),
  cap_sender: Option(String),
  cap_identifier: Option(String),
  outcome: String,
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.wis2_notification
       (data_id, notification_id, centre_id, kind, topic, channel,
        pubtime, received_at, fetched_via, download_url, cap_sender, cap_identifier, outcome)
     VALUES
       ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
     ON CONFLICT (data_id) DO UPDATE SET
       notification_id = EXCLUDED.notification_id,
       centre_id = EXCLUDED.centre_id,
       kind = EXCLUDED.kind,
       topic = EXCLUDED.topic,
       channel = EXCLUDED.channel,
       pubtime = EXCLUDED.pubtime,
       received_at = EXCLUDED.received_at,
       fetched_via = EXCLUDED.fetched_via,
       download_url = EXCLUDED.download_url,
       cap_sender = EXCLUDED.cap_sender,
       cap_identifier = EXCLUDED.cap_identifier,
       outcome = EXCLUDED.outcome",
  )
  |> pog.parameter(pog.text(data_id))
  |> pog.parameter(pog.text(notification_id))
  |> pog.parameter(pog.text(centre_id))
  |> pog.parameter(pog.text(kind))
  |> pog.parameter(pog.text(topic))
  |> pog.parameter(pog.text(channel))
  |> pog.parameter(pog.nullable(pog.timestamp, pubtime))
  |> pog.parameter(pog.timestamp(received_at))
  |> pog.parameter(pog.text(fetched_via))
  |> pog.parameter(pog.nullable(pog.text, download_url))
  |> pog.parameter(pog.nullable(pog.text, cap_sender))
  |> pog.parameter(pog.nullable(pog.text, cap_identifier))
  |> pog.parameter(pog.text(outcome))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub fn cleanup(cutoff: Timestamp, conn: pog.Connection) -> Result(Nil, String) {
  use _ <- result.try(
    pog.query("DELETE FROM sea.wis2_notification WHERE received_at < $1")
    |> pog.parameter(pog.timestamp(cutoff))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err),
  )
  use _ <- result.try(
    pog.query("DELETE FROM sea.wis2_tc_track WHERE received_at < $1")
    |> pog.parameter(pog.timestamp(cutoff))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err),
  )
  pog.query(
    "DELETE FROM sea.hazard WHERE hazard_type = 'observed_extreme' AND NOT is_current AND modified_at < $1",
  )
  |> pog.parameter(pog.timestamp(cutoff))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub fn upsert_source(s: Source, conn: pog.Connection) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (id) DO UPDATE SET
       name = EXCLUDED.name,
       license = CASE WHEN EXCLUDED.license <> 'Unknown' THEN EXCLUDED.license ELSE sea.source.license END,
       attribution_text = EXCLUDED.attribution_text,
       priority = EXCLUDED.priority",
  )
  |> pog.parameter(pog.text(s.id))
  |> pog.parameter(pog.text(s.name))
  |> pog.parameter(pog.nullable(pog.text, s.homepage))
  |> pog.parameter(pog.text(s.license))
  |> pog.parameter(pog.text(s.attribution_text))
  |> pog.parameter(pog.bool(s.redistributable))
  |> pog.parameter(pog.int(s.priority))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub type AreaWriteOutcome {
  AreaInserted
  AreaUpgraded
  AreaReplaced
  AreaSkipped
}

pub fn is_new_area_outcome(outcome: AreaWriteOutcome) -> Bool {
  case outcome {
    AreaInserted | AreaUpgraded -> True
    AreaReplaced | AreaSkipped -> False
  }
}

pub fn read_area_precision(
  cap_sender: String,
  cap_identifier: String,
  area_key: String,
  conn: pog.Connection,
) -> Result(Option(AreaPrecision), String) {
  pog.query(
    "SELECT precision FROM sea.wis2_cap_area WHERE cap_sender = $1 AND cap_identifier = $2 AND area_key = $3",
  )
  |> pog.parameter(pog.text(cap_sender))
  |> pog.parameter(pog.text(cap_identifier))
  |> pog.parameter(pog.text(area_key))
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(conn)
  |> result.map(fn(x) {
    case list.first(x.rows) {
      Ok(s) -> wis2.area_precision_from_string(s) |> option.from_result
      Error(Nil) -> None
    }
  })
  |> result.map_error(err)
}

pub fn area_exists(
  cap_sender: String,
  cap_identifier: String,
  area_key: String,
  conn: pog.Connection,
) -> Result(Bool, String) {
  read_area_precision(cap_sender, cap_identifier, area_key, conn)
  |> result.map(option.is_some)
}

pub fn upsert_area(
  cap_sender: String,
  cap_identifier: String,
  area_key: String,
  geom_geojson: String,
  precision: AreaPrecision,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(AreaWriteOutcome, String) {
  use stored_precision <- result.try(read_area_precision(
    cap_sender,
    cap_identifier,
    area_key,
    conn,
  ))
  case wis2.should_replace_area(precision, stored_precision) {
    False -> Ok(AreaSkipped)
    True -> {
      use _ <- result.try(raw_upsert_area(
        cap_sender,
        cap_identifier,
        area_key,
        geom_geojson,
        precision,
        now,
        conn,
      ))
      case stored_precision, precision {
        None, _ -> Ok(AreaInserted)
        Some(wis2.Bbox), wis2.Exact -> Ok(AreaUpgraded)
        _, _ -> Ok(AreaReplaced)
      }
    }
  }
}

pub fn raw_upsert_area(
  cap_sender: String,
  cap_identifier: String,
  area_key: String,
  geom_geojson: String,
  precision: AreaPrecision,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.wis2_cap_area (cap_sender, cap_identifier, area_key, geom, precision, received_at)
     VALUES ($1, $2, $3, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON($4::text), 4326)), 3)), $5, $6)
     ON CONFLICT (cap_sender, cap_identifier, area_key) DO UPDATE SET
       geom = EXCLUDED.geom,
       precision = EXCLUDED.precision,
       received_at = EXCLUDED.received_at",
  )
  |> pog.parameter(pog.text(cap_sender))
  |> pog.parameter(pog.text(cap_identifier))
  |> pog.parameter(pog.text(area_key))
  |> pog.parameter(pog.text(geom_geojson))
  |> pog.parameter(pog.text(wis2.area_precision_to_string(precision)))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

const update_alert_geom_sql = "
  WITH written AS (
    UPDATE sea.alert SET
      geom = (
        SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_UnaryUnion(ST_Collect(geom))), 3))
        FROM sea.wis2_cap_area
        WHERE cap_sender = $1::text AND cap_identifier = $2::text AND geom IS NOT NULL
      )
    WHERE (sender = $1::text AND identifier = $2::text) OR source_id = $1::text || ',' || $2::text
    RETURNING *
  )
  SELECT "
  <> alert.columns
  <> "
  FROM written a
  JOIN sea.source s ON s.id = a.source"

pub fn update_alert_geometry_from_areas(
  cap_sender: String,
  cap_identifier: String,
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.query(update_alert_geom_sql)
  |> pog.parameter(pog.text(cap_sender))
  |> pog.parameter(pog.text(cap_identifier))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

pub fn write_broker(
  url: String,
  connected: Bool,
  error: Option(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.wis2_broker (id, url, connected, error, last_report_at)
     VALUES (1, $1, $2, $3, $4)
     ON CONFLICT (id) DO UPDATE SET
       url = EXCLUDED.url,
       connected = EXCLUDED.connected,
       error = EXCLUDED.error,
       last_report_at = EXCLUDED.last_report_at",
  )
  |> pog.parameter(pog.text(url))
  |> pog.parameter(pog.bool(connected))
  |> pog.parameter(pog.nullable(pog.text, error))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub fn write_health_bucket(
  centre_id: String,
  kind: String,
  bucket_start: Timestamp,
  received: Int,
  duplicates: Int,
  download_failed: Int,
  decode_failed: Int,
  integrity_failed: Int,
  last_received_at: Option(Timestamp),
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.wis2_health_bucket (
       centre_id, kind, bucket_start,
       received, duplicates, download_failed, decode_failed, integrity_failed,
       last_received_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
     ON CONFLICT (centre_id, kind, bucket_start) DO UPDATE SET
       received = sea.wis2_health_bucket.received + EXCLUDED.received,
       duplicates = sea.wis2_health_bucket.duplicates + EXCLUDED.duplicates,
       download_failed = sea.wis2_health_bucket.download_failed + EXCLUDED.download_failed,
       decode_failed = sea.wis2_health_bucket.decode_failed + EXCLUDED.decode_failed,
       integrity_failed = sea.wis2_health_bucket.integrity_failed + EXCLUDED.integrity_failed,
       last_received_at = CASE
         WHEN sea.wis2_health_bucket.last_received_at IS NULL THEN EXCLUDED.last_received_at
         WHEN EXCLUDED.last_received_at IS NULL THEN sea.wis2_health_bucket.last_received_at
         ELSE GREATEST(sea.wis2_health_bucket.last_received_at, EXCLUDED.last_received_at)
       END",
  )
  |> pog.parameter(pog.text(centre_id))
  |> pog.parameter(pog.text(kind))
  |> pog.parameter(pog.timestamp(bucket_start))
  |> pog.parameter(pog.int(received))
  |> pog.parameter(pog.int(duplicates))
  |> pog.parameter(pog.int(download_failed))
  |> pog.parameter(pog.int(decode_failed))
  |> pog.parameter(pog.int(integrity_failed))
  |> pog.parameter(pog.nullable(pog.timestamp, last_received_at))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub fn read_health_summary(
  now: Timestamp,
  conn: pog.Connection,
) -> Result(#(BrokerState, List(ChannelHealth)), String) {
  use broker <- result.try(read_broker(conn))
  let cutoff_24h = timestamp.subtract(now, duration.hours(24))
  use channels <- result.try(read_channels_24h(cutoff_24h, now, conn))
  Ok(#(broker, channels))
}

fn read_broker(conn: pog.Connection) -> Result(BrokerState, String) {
  let decoder = {
    use url <- decode.field(0, decode.string)
    use connected <- decode.field(1, decode.bool)
    use error <- decode.field(2, decode.optional(decode.string))
    use last_report_at <- decode.field(
      3,
      decode.optional(alert.timestamptz_decoder()),
    )
    decode.success(BrokerState(url:, connected:, last_report_at:, error:))
  }
  pog.query(
    "SELECT url, connected, error, last_report_at FROM sea.wis2_broker WHERE id = 1",
  )
  |> pog.returning(decoder)
  |> pog.execute(conn)
  |> result.map(fn(x) {
    case list.first(x.rows) {
      Ok(b) -> b
      Error(Nil) ->
        BrokerState(
          url: "",
          connected: False,
          last_report_at: None,
          error: None,
        )
    }
  })
  |> result.map_error(err)
}

type ChannelRow {
  ChannelRow(
    centre_id: String,
    kind: String,
    received_24h: Int,
    duplicates_24h: Int,
    download_failed_24h: Int,
    decode_failed_24h: Int,
    integrity_failed_24h: Int,
    last_received_at: Option(Timestamp),
  )
}

fn read_channels_24h(
  cutoff_24h: Timestamp,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(ChannelHealth), String) {
  let decoder = {
    use centre_id <- decode.field(0, decode.string)
    use kind <- decode.field(1, decode.string)
    use received_24h <- decode.field(2, decode.int)
    use duplicates_24h <- decode.field(3, decode.int)
    use download_failed_24h <- decode.field(4, decode.int)
    use decode_failed_24h <- decode.field(5, decode.int)
    use integrity_failed_24h <- decode.field(6, decode.int)
    use last_received_at <- decode.field(
      7,
      decode.optional(alert.timestamptz_decoder()),
    )
    decode.success(ChannelRow(
      centre_id:,
      kind:,
      received_24h:,
      duplicates_24h:,
      download_failed_24h:,
      decode_failed_24h:,
      integrity_failed_24h:,
      last_received_at:,
    ))
  }
  pog.query(
    "SELECT centre_id, kind,
            COALESCE(SUM(received), 0)::integer,
            COALESCE(SUM(duplicates), 0)::integer,
            COALESCE(SUM(download_failed), 0)::integer,
            COALESCE(SUM(decode_failed), 0)::integer,
            COALESCE(SUM(integrity_failed), 0)::integer,
            MAX(last_received_at)
     FROM sea.wis2_health_bucket
     WHERE bucket_start >= $1
     GROUP BY centre_id, kind
     ORDER BY centre_id ASC, kind ASC",
  )
  |> pog.parameter(pog.timestamp(cutoff_24h))
  |> pog.returning(decoder)
  |> pog.execute(conn)
  |> result.map(fn(x) {
    list.map(x.rows, fn(row) {
      let status =
        wis2.compute_status(
          row.kind,
          row.received_24h,
          row.download_failed_24h,
          row.decode_failed_24h,
          row.integrity_failed_24h,
          row.last_received_at,
          now,
        )
      ChannelHealth(
        centre_id: row.centre_id,
        kind: row.kind,
        received_24h: row.received_24h,
        duplicates_24h: row.duplicates_24h,
        download_failed_24h: row.download_failed_24h,
        decode_failed_24h: row.decode_failed_24h,
        integrity_failed_24h: row.integrity_failed_24h,
        last_received_at: row.last_received_at,
        status:,
      )
    })
  })
  |> result.map_error(err)
}

pub fn upsert_tc_source(
  centre_id: String,
  conn: pog.Connection,
) -> Result(Nil, String) {
  let s = wis2.make_tc_source(centre_id)
  pog.query(
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (id) DO NOTHING",
  )
  |> pog.parameter(pog.text(s.id))
  |> pog.parameter(pog.text(s.name))
  |> pog.parameter(pog.nullable(pog.text, s.homepage))
  |> pog.parameter(pog.text(s.license))
  |> pog.parameter(pog.text(s.attribution_text))
  |> pog.parameter(pog.bool(s.redistributable))
  |> pog.parameter(pog.int(s.priority))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub fn track_exists(
  source: String,
  storm_id: String,
  analysis_time: Timestamp,
  conn: pog.Connection,
) -> Result(Bool, String) {
  pog.query(
    "SELECT 1 FROM sea.wis2_tc_track WHERE source = $1::text AND storm_id = $2::text AND analysis_time = $3",
  )
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(storm_id))
  |> pog.parameter(pog.timestamp(analysis_time))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(x) { !list.is_empty(x.rows) })
  |> result.map_error(err)
}

pub fn load_active_gdacs_tc_hazards(
  conn: pog.Connection,
) -> Result(List(Hazard), String) {
  pog.query(
    "SELECT "
    <> hazard.columns
    <> " FROM sea.hazard WHERE source = 'gdacs' AND hazard_type = 'tropical_cyclone' AND is_current",
  )
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

pub fn write_tc_track(
  feature: Wis2TcFeature,
  source: String,
  analysis_time: Timestamp,
  matched_hazard_source: Option(String),
  matched_hazard_source_id: Option(String),
  received_at: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  let points_json =
    json.to_string(json.array(feature.points, wis2.forecast_point_to_json))
  let track_geom = wis2.points_to_linestring_geojson(feature.points)

  pog.query(
    "INSERT INTO sea.wis2_tc_track
       (source, storm_id, analysis_time, storm_name, centre_id, data_id,
        originating_centre, ensemble_member, points, track,
        matched_hazard_source, matched_hazard_source_id, received_at)
     VALUES
       ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb,
        CASE WHEN $10::text IS NOT NULL THEN ST_SetSRID(ST_GeomFromGeoJSON($10::text), 4326) ELSE NULL END,
        $11, $12, $13)
     ON CONFLICT (source, storm_id, analysis_time) DO NOTHING",
  )
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(feature.storm_id))
  |> pog.parameter(pog.timestamp(analysis_time))
  |> pog.parameter(pog.nullable(pog.text, feature.storm_name))
  |> pog.parameter(pog.text(feature.centre_id))
  |> pog.parameter(pog.text(feature.data_id))
  |> pog.parameter(pog.int(feature.originating_centre))
  |> pog.parameter(pog.nullable(pog.int, feature.ensemble_member))
  |> pog.parameter(pog.text(points_json))
  |> pog.parameter(pog.nullable(pog.text, track_geom))
  |> pog.parameter(pog.nullable(pog.text, matched_hazard_source))
  |> pog.parameter(pog.nullable(pog.text, matched_hazard_source_id))
  |> pog.parameter(pog.timestamp(received_at))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

const tc_hazard_insert_sql = "INSERT INTO sea.hazard (source,source_id,source_episode_id,episode_count,hazard_type,hazard_codes,glide,alert_level,alert_score,cap_severity,severity_value,severity_unit,severity_label,estimate_type,title,description,countries,report_url,external_ids,onset_at,onset_at_ms,expires_at,expires_at_ms,modified_at,modified_at_ms,is_current,centroid,bbox,primary_geometry,geometries,first_seen_at,last_seen_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,to_timestamp($20::double precision/1000),$20,to_timestamp($21::double precision/1000),$21,to_timestamp($22::double precision/1000),$22,$23,ST_SetSRID(ST_MakePoint($24,$25),4326),ST_SetSRID(ST_MakeEnvelope($26,$27,$28,$29),4326),ST_SetSRID(ST_GeomFromGeoJSON($30::text),4326),$31::jsonb,to_timestamp($32::double precision/1000),to_timestamp($32::double precision/1000)) RETURNING "

const tc_hazard_update_sql = "UPDATE sea.hazard SET alert_level=$3::text,cap_severity=$4::text,severity_value=$5::double precision,title=$6::text,description=$7,expires_at=to_timestamp($8::double precision/1000),expires_at_ms=$8,modified_at=to_timestamp($9::double precision/1000),modified_at_ms=$9,is_current=$10,centroid=ST_SetSRID(ST_MakePoint($11,$12),4326),bbox=ST_SetSRID(ST_MakeEnvelope($13,$14,$15,$16),4326),primary_geometry=ST_SetSRID(ST_GeomFromGeoJSON($17::text),4326),geometries=$18::jsonb,last_seen_at=to_timestamp($19::double precision/1000) WHERE source=$1::text AND source_id=$2::text RETURNING "

pub fn upsert_own_tc_hazard(
  feature: Wis2TcFeature,
  source: String,
  analysis_time_ms: Int,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(#(Hazard, Bool), String) {
  let source_id =
    wis2.tc_hazard_source_id(feature.storm_id, feature.analysis_time)
  let now_ms = timestamp_to_ms(now)

  use exists <- result.try(own_tc_hazard_exists(source, source_id, conn))
  case exists {
    True -> {
      pog.query(tc_hazard_update_sql <> hazard.columns)
      |> bind_tc_hazard_update_params(source, source_id, feature, now_ms)
      |> pog.returning(hazard.row_decoder())
      |> pog.execute(conn)
      |> result.map_error(err)
      |> result.try(fn(x) {
        case x.rows {
          [row] -> Ok(#(row, False))
          _ -> Error("hazard update returned no row for " <> source_id)
        }
      })
    }
    False -> {
      pog.query(tc_hazard_insert_sql <> hazard.columns)
      |> bind_tc_hazard_params(
        source,
        source_id,
        feature,
        analysis_time_ms,
        now_ms,
      )
      |> pog.returning(hazard.row_decoder())
      |> pog.execute(conn)
      |> result.map_error(err)
      |> result.try(fn(x) {
        case x.rows {
          [row] -> Ok(#(row, True))
          _ -> Error("hazard insert returned no row for " <> source_id)
        }
      })
    }
  }
}

fn own_tc_hazard_exists(
  source: String,
  source_id: String,
  conn: pog.Connection,
) -> Result(Bool, String) {
  pog.query(
    "SELECT 1 FROM sea.hazard WHERE source = $1::text AND source_id = $2::text FOR UPDATE",
  )
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(x) { !list.is_empty(x.rows) })
  |> result.map_error(err)
}

fn bind_tc_hazard_params(
  query: pog.Query(a),
  source: String,
  source_id: String,
  feature: Wis2TcFeature,
  analysis_time_ms: Int,
  now_ms: Int,
) -> pog.Query(a) {
  let alert_level = wis2.calculate_alert_level(feature.points)
  let cap_severity = hazard.cap_severity_for(alert_level)
  let severity_value = wis2.max_wind_from_points(feature.points)
  let title = option.unwrap(feature.storm_name, feature.storm_id)
  let description = Some("Tropical cyclone " <> title)
  let expires_at_ms = case list.last(feature.points) {
    Ok(last_pt) ->
      case cap.parse_rfc3339(last_pt.time) {
        Ok(t) -> Some(timestamp_to_ms(t))
        Error(_) -> None
      }
    Error(_) -> None
  }
  let #(centroid_lon, centroid_lat) = wis2.points_to_centroid(feature.points)
  let #(bbox_w, bbox_s, bbox_e, bbox_n) = case
    wis2.points_to_bbox(feature.points)
  {
    Some(#(w, s, e, n)) -> #(Some(w), Some(s), Some(e), Some(n))
    None -> #(None, None, None, None)
  }
  let primary_geom = wis2.points_to_linestring_geojson(feature.points)
  let geometries =
    wis2.track_to_feature_collection_geojson(
      feature.storm_id,
      feature.storm_name,
      feature.analysis_time,
      feature.points,
    )

  query
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.parameter(pog.nullable(pog.text, None))
  |> pog.parameter(pog.int(1))
  |> pog.parameter(pog.text("tropical_cyclone"))
  |> pog.parameter(pog.array(pog.text, hazard.hazard_codes_for("TC")))
  |> pog.parameter(pog.nullable(pog.text, None))
  |> pog.parameter(pog.text(alert_level))
  |> pog.parameter(pog.nullable(pog.float, None))
  |> pog.parameter(pog.text(cap_severity))
  |> pog.parameter(pog.nullable(pog.float, severity_value))
  |> pog.parameter(pog.nullable(pog.text, Some("m/s")))
  |> pog.parameter(pog.nullable(pog.text, None))
  |> pog.parameter(pog.text(hazard.estimate_type))
  |> pog.parameter(pog.text(title))
  |> pog.parameter(pog.nullable(pog.text, description))
  |> pog.parameter(pog.array(pog.text, []))
  |> pog.parameter(pog.nullable(pog.text, feature.download_url))
  |> pog.parameter(pog.array(pog.text, []))
  |> pog.parameter(pog.int(analysis_time_ms))
  |> pog.parameter(pog.nullable(pog.int, expires_at_ms))
  |> pog.parameter(pog.int(now_ms))
  |> pog.parameter(pog.bool(True))
  |> pog.parameter(pog.float(centroid_lon))
  |> pog.parameter(pog.float(centroid_lat))
  |> pog.parameter(pog.nullable(pog.float, bbox_w))
  |> pog.parameter(pog.nullable(pog.float, bbox_s))
  |> pog.parameter(pog.nullable(pog.float, bbox_e))
  |> pog.parameter(pog.nullable(pog.float, bbox_n))
  |> pog.parameter(pog.nullable(pog.text, primary_geom))
  |> pog.parameter(pog.nullable(pog.text, geometries))
  |> pog.parameter(pog.int(now_ms))
}

fn bind_tc_hazard_update_params(
  query: pog.Query(a),
  source: String,
  source_id: String,
  feature: Wis2TcFeature,
  now_ms: Int,
) -> pog.Query(a) {
  let alert_level = wis2.calculate_alert_level(feature.points)
  let cap_severity = hazard.cap_severity_for(alert_level)
  let severity_value = wis2.max_wind_from_points(feature.points)
  let title = option.unwrap(feature.storm_name, feature.storm_id)
  let description = Some("Tropical cyclone " <> title)
  let expires_at_ms = case list.last(feature.points) {
    Ok(last_pt) ->
      case cap.parse_rfc3339(last_pt.time) {
        Ok(t) -> Some(timestamp_to_ms(t))
        Error(_) -> None
      }
    Error(_) -> None
  }
  let #(centroid_lon, centroid_lat) = wis2.points_to_centroid(feature.points)
  let #(bbox_w, bbox_s, bbox_e, bbox_n) = case
    wis2.points_to_bbox(feature.points)
  {
    Some(#(w, s, e, n)) -> #(Some(w), Some(s), Some(e), Some(n))
    None -> #(None, None, None, None)
  }
  let primary_geom = wis2.points_to_linestring_geojson(feature.points)
  let geometries =
    wis2.track_to_feature_collection_geojson(
      feature.storm_id,
      feature.storm_name,
      feature.analysis_time,
      feature.points,
    )

  query
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.parameter(pog.text(alert_level))
  |> pog.parameter(pog.text(cap_severity))
  |> pog.parameter(pog.nullable(pog.float, severity_value))
  |> pog.parameter(pog.text(title))
  |> pog.parameter(pog.nullable(pog.text, description))
  |> pog.parameter(pog.nullable(pog.int, expires_at_ms))
  |> pog.parameter(pog.int(now_ms))
  |> pog.parameter(pog.bool(True))
  |> pog.parameter(pog.float(centroid_lon))
  |> pog.parameter(pog.float(centroid_lat))
  |> pog.parameter(pog.nullable(pog.float, bbox_w))
  |> pog.parameter(pog.nullable(pog.float, bbox_s))
  |> pog.parameter(pog.nullable(pog.float, bbox_e))
  |> pog.parameter(pog.nullable(pog.float, bbox_n))
  |> pog.parameter(pog.nullable(pog.text, primary_geom))
  |> pog.parameter(pog.nullable(pog.text, geometries))
  |> pog.parameter(pog.int(now_ms))
}

pub fn end_own_tc_hazards_for_storm(
  source: String,
  storm_id: String,
  now_ms: Int,
  conn: pog.Connection,
) -> Result(List(Hazard), String) {
  pog.query("UPDATE sea.hazard
     SET is_current = false,
         modified_at = to_timestamp($1::double precision / 1000),
         modified_at_ms = $1,
         last_seen_at = to_timestamp($1::double precision / 1000)
     WHERE source = $2::text
       AND source_id LIKE $3::text
       AND is_current
     RETURNING " <> hazard.columns)
  |> pog.parameter(pog.int(now_ms))
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(storm_id <> "/%"))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

pub fn link_older_tracks_to_hazard(
  source: String,
  storm_id: String,
  matched_source: String,
  matched_source_id: String,
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.wis2_tc_track
     SET matched_hazard_source = $1::text,
         matched_hazard_source_id = $2::text
     WHERE source = $3::text AND storm_id = $4::text",
  )
  |> pog.parameter(pog.text(matched_source))
  |> pog.parameter(pog.text(matched_source_id))
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(storm_id))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub fn latest_forecast_tracks_for_hazard(
  matched_source: String,
  matched_source_id: String,
  conn: pog.Connection,
) -> Result(List(ForecastTrack), String) {
  let decoder = {
    use source <- decode.field(0, decode.string)
    use centre_id <- decode.field(1, decode.string)
    use storm_id <- decode.field(2, decode.string)
    use storm_name <- decode.field(3, decode.optional(decode.string))
    use analysis_time <- decode.field(4, decode.string)
    use points_text <- decode.field(5, decode.string)
    decode.success(#(
      source,
      centre_id,
      storm_id,
      storm_name,
      analysis_time,
      points_text,
    ))
  }
  pog.query(
    "SELECT DISTINCT ON (centre_id)
       source, centre_id, storm_id, storm_name,
       to_char(analysis_time AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
       points::text
     FROM sea.wis2_tc_track
     WHERE matched_hazard_source = $1::text AND matched_hazard_source_id = $2::text
     ORDER BY centre_id, analysis_time DESC",
  )
  |> pog.parameter(pog.text(matched_source))
  |> pog.parameter(pog.text(matched_source_id))
  |> pog.returning(decoder)
  |> pog.execute(conn)
  |> result.map(fn(x) {
    list.map(x.rows, fn(row) {
      let #(source, centre_id, storm_id, storm_name, analysis_time, points_text) =
        row
      let points = case json.parse(points_text, wis2.points_decoder()) {
        Ok(pts) -> pts
        Error(_) -> []
      }
      ForecastTrack(
        source:,
        centre_id:,
        storm_id:,
        storm_name:,
        analysis_time:,
        points:,
      )
    })
  })
  |> result.map_error(err)
}

fn timestamp_to_ms(ts: Timestamp) -> Int {
  let #(sec, nano) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  sec * 1000 + nano / 1_000_000
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}

pub fn upsert_observation_source(
  centre_id: String,
  conn: pog.Connection,
) -> Result(Nil, String) {
  let s = wis2.make_source(centre_id, None)
  pog.query(
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ($1, $2, $3, $4, $5, $6, 70)
     ON CONFLICT (id) DO NOTHING",
  )
  |> pog.parameter(pog.text(s.id))
  |> pog.parameter(pog.text(s.name))
  |> pog.parameter(pog.nullable(pog.text, s.homepage))
  |> pog.parameter(pog.text(s.license))
  |> pog.parameter(pog.text(s.attribution_text))
  |> pog.parameter(pog.bool(s.redistributable))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

pub type StationUpsert {
  StationUpsert(
    station_id: String,
    name: Option(String),
    lat: Float,
    lon: Float,
    elevation_m: Option(Float),
    observed_at: Timestamp,
    wind_speed_ms: Option(Float),
    gust_ms: Option(Float),
    precip_1h_mm: Option(Float),
    precip_24h_mm: Option(Float),
    mslp_hpa: Option(Float),
  )
}

const batch_upsert_stations_sql = "
  INSERT INTO sea.wis2_station (
    station_id, name, lat, lon, elevation_m, geom, last_observed_at,
    wind_speed_ms, wind_observed_at,
    gust_ms, gust_observed_at,
    precip_1h_mm, precip_1h_observed_at,
    precip_24h_mm, precip_24h_observed_at,
    mslp_hpa, mslp_observed_at,
    updated_at
  )
  SELECT
    s.station_id,
    s.name,
    s.lat,
    s.lon,
    s.elevation_m,
    ST_SetSRID(ST_MakePoint(s.lon, s.lat), 4326),
    s.observed_at,
    s.wind_speed_ms,
    CASE WHEN s.wind_speed_ms IS NOT NULL THEN s.observed_at ELSE NULL END,
    s.gust_ms,
    CASE WHEN s.gust_ms IS NOT NULL THEN s.observed_at ELSE NULL END,
    s.precip_1h_mm,
    CASE WHEN s.precip_1h_mm IS NOT NULL THEN s.observed_at ELSE NULL END,
    s.precip_24h_mm,
    CASE WHEN s.precip_24h_mm IS NOT NULL THEN s.observed_at ELSE NULL END,
    s.mslp_hpa,
    CASE WHEN s.mslp_hpa IS NOT NULL THEN s.observed_at ELSE NULL END,
    now()
  FROM (
    SELECT DISTINCT ON (u.station_id)
      u.station_id, u.name, u.lat, u.lon, u.elevation_m, u.observed_at,
      u.wind_speed_ms, u.gust_ms, u.precip_1h_mm, u.precip_24h_mm, u.mslp_hpa
    FROM unnest(
      $1::text[], $2::text[], $3::double precision[], $4::double precision[], $5::double precision[],
      $6::timestamptz[],
      $7::double precision[], $8::double precision[], $9::double precision[], $10::double precision[], $11::double precision[]
    ) AS u(
      station_id, name, lat, lon, elevation_m, observed_at,
      wind_speed_ms, gust_ms, precip_1h_mm, precip_24h_mm, mslp_hpa
    )
    ORDER BY u.station_id, u.observed_at DESC
  ) AS s
  ON CONFLICT (station_id) DO UPDATE SET
    name = COALESCE(EXCLUDED.name, sea.wis2_station.name),
    lat = EXCLUDED.lat,
    lon = EXCLUDED.lon,
    elevation_m = COALESCE(EXCLUDED.elevation_m, sea.wis2_station.elevation_m),
    geom = EXCLUDED.geom,
    last_observed_at = GREATEST(sea.wis2_station.last_observed_at, EXCLUDED.last_observed_at),
    wind_speed_ms = CASE WHEN EXCLUDED.wind_speed_ms IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.wind_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.wind_speed_ms ELSE sea.wis2_station.wind_speed_ms END,
    wind_observed_at = CASE WHEN EXCLUDED.wind_speed_ms IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.wind_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.last_observed_at ELSE sea.wis2_station.wind_observed_at END,
    gust_ms = CASE WHEN EXCLUDED.gust_ms IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.gust_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.gust_ms ELSE sea.wis2_station.gust_ms END,
    gust_observed_at = CASE WHEN EXCLUDED.gust_ms IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.gust_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.last_observed_at ELSE sea.wis2_station.gust_observed_at END,
    precip_1h_mm = CASE WHEN EXCLUDED.precip_1h_mm IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.precip_1h_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.precip_1h_mm ELSE sea.wis2_station.precip_1h_mm END,
    precip_1h_observed_at = CASE WHEN EXCLUDED.precip_1h_mm IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.precip_1h_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.last_observed_at ELSE sea.wis2_station.precip_1h_observed_at END,
    precip_24h_mm = CASE WHEN EXCLUDED.precip_24h_mm IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.precip_24h_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.precip_24h_mm ELSE sea.wis2_station.precip_24h_mm END,
    precip_24h_observed_at = CASE WHEN EXCLUDED.precip_24h_mm IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.precip_24h_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.last_observed_at ELSE sea.wis2_station.precip_24h_observed_at END,
    mslp_hpa = CASE WHEN EXCLUDED.mslp_hpa IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.mslp_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.mslp_hpa ELSE sea.wis2_station.mslp_hpa END,
    mslp_observed_at = CASE WHEN EXCLUDED.mslp_hpa IS NOT NULL AND EXCLUDED.last_observed_at >= COALESCE(sea.wis2_station.mslp_observed_at, '-infinity'::timestamptz) THEN EXCLUDED.last_observed_at ELSE sea.wis2_station.mslp_observed_at END,
    updated_at = now()"

pub fn upsert_stations_batch(
  stations: List(StationUpsert),
  conn: pog.Connection,
) -> Result(Nil, String) {
  case stations {
    [] -> Ok(Nil)
    _ -> {
      let station_ids = list.map(stations, fn(s) { s.station_id })
      let names = list.map(stations, fn(s) { s.name })
      let lats = list.map(stations, fn(s) { s.lat })
      let lons = list.map(stations, fn(s) { s.lon })
      let elevations = list.map(stations, fn(s) { s.elevation_m })
      let observed_ats = list.map(stations, fn(s) { s.observed_at })
      let winds = list.map(stations, fn(s) { s.wind_speed_ms })
      let gusts = list.map(stations, fn(s) { s.gust_ms })
      let precip_1hs = list.map(stations, fn(s) { s.precip_1h_mm })
      let precip_24hs = list.map(stations, fn(s) { s.precip_24h_mm })
      let mslps = list.map(stations, fn(s) { s.mslp_hpa })

      pog.query(batch_upsert_stations_sql)
      |> pog.parameter(pog.array(pog.text, station_ids))
      |> pog.parameter(pog.array(fn(x) { pog.nullable(pog.text, x) }, names))
      |> pog.parameter(pog.array(pog.float, lats))
      |> pog.parameter(pog.array(pog.float, lons))
      |> pog.parameter(pog.array(
        fn(x) { pog.nullable(pog.float, x) },
        elevations,
      ))
      |> pog.parameter(pog.array(pog.timestamp, observed_ats))
      |> pog.parameter(pog.array(fn(x) { pog.nullable(pog.float, x) }, winds))
      |> pog.parameter(pog.array(fn(x) { pog.nullable(pog.float, x) }, gusts))
      |> pog.parameter(pog.array(
        fn(x) { pog.nullable(pog.float, x) },
        precip_1hs,
      ))
      |> pog.parameter(pog.array(
        fn(x) { pog.nullable(pog.float, x) },
        precip_24hs,
      ))
      |> pog.parameter(pog.array(fn(x) { pog.nullable(pog.float, x) }, mslps))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)
      |> result.map(fn(_) { Nil })
      |> result.map_error(err)
    }
  }
}

pub fn fetch_neighbour_candidates(
  station_id: String,
  lon: Float,
  lat: Float,
  conn: pog.Connection,
) -> Result(List(StationNeighbour), String) {
  let decoder = {
    use st_id <- decode.field(0, decode.string)
    use n_lat <- decode.field(1, decode.float)
    use n_lon <- decode.field(2, decode.float)
    use wind_speed <- decode.field(3, decode.optional(decode.float))
    use wind_ts <- decode.field(4, decode.optional(decode.int))
    use gust <- decode.field(5, decode.optional(decode.float))
    use gust_ts <- decode.field(6, decode.optional(decode.int))
    use rain1h <- decode.field(7, decode.optional(decode.float))
    use rain1h_ts <- decode.field(8, decode.optional(decode.int))
    use rain24h <- decode.field(9, decode.optional(decode.float))
    use rain24h_ts <- decode.field(10, decode.optional(decode.int))
    use mslp <- decode.field(11, decode.optional(decode.float))
    use mslp_ts <- decode.field(12, decode.optional(decode.int))
    decode.success(StationNeighbour(
      station_id: st_id,
      lat: n_lat,
      lon: n_lon,
      wind_speed_ms: wind_speed,
      wind_observed_at_ms: wind_ts,
      gust_ms: gust,
      gust_observed_at_ms: gust_ts,
      precip_1h_mm: rain1h,
      precip_1h_observed_at_ms: rain1h_ts,
      precip_24h_mm: rain24h,
      precip_24h_observed_at_ms: rain24h_ts,
      mslp_hpa: mslp,
      mslp_observed_at_ms: mslp_ts,
    ))
  }
  pog.query(
    "SELECT
       station_id,
       lat,
       lon,
       wind_speed_ms,
       (extract(epoch from wind_observed_at) * 1000)::bigint,
       gust_ms,
       (extract(epoch from gust_observed_at) * 1000)::bigint,
       precip_1h_mm,
       (extract(epoch from precip_1h_observed_at) * 1000)::bigint,
       precip_24h_mm,
       (extract(epoch from precip_24h_observed_at) * 1000)::bigint,
       mslp_hpa,
       (extract(epoch from mslp_observed_at) * 1000)::bigint
     FROM sea.wis2_station
     WHERE station_id <> $1
       AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography, 150000)",
  )
  |> pog.parameter(pog.text(station_id))
  |> pog.parameter(pog.float(lon))
  |> pog.parameter(pog.float(lat))
  |> pog.returning(decoder)
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

pub fn find_active_episode(
  station_id: String,
  subtype: String,
  conn: pog.Connection,
) -> Result(Option(Hazard), String) {
  let prefix = station_id <> "/" <> subtype <> "/%"
  pog.query("SELECT " <> hazard.columns <> " FROM sea.hazard
       WHERE hazard_type = 'observed_extreme'
         AND subtype = $1
         AND is_current
         AND source_id LIKE $2
       ORDER BY modified_at_ms DESC
       LIMIT 1")
  |> pog.parameter(pog.text(subtype))
  |> pog.parameter(pog.text(prefix))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
  |> result.map_error(err)
}

pub fn create_observed_extreme_episode(
  source: String,
  source_id: String,
  subtype: String,
  confirmed: Bool,
  value: Float,
  unit: String,
  label: String,
  title: String,
  station_id: String,
  station_name: Option(String),
  obs_time_ms: Int,
  now_ms: Int,
  lon: Float,
  lat: Float,
  conn: pog.Connection,
) -> Result(Hazard, String) {
  let expires_at_ms = obs_time_ms + 3 * 3600 * 1000
  let primary_geom = wis2_observation.point_geojson(lon, lat)
  let subtype_enum =
    wis2_observation.subtype_from_string(subtype)
    |> result.unwrap(wis2_observation.SubtypeWind)
  let geometries =
    wis2_observation.episode_feature_collection_geojson(
      station_id,
      station_name,
      subtype_enum,
      value,
      unit,
      lon,
      lat,
    )
  let alert_level = "orange"
  let cap_severity = "severe"
  let description =
    Some(
      "Observed extreme "
      <> subtype
      <> " at "
      <> wis2_observation.format_station_label(station_id, station_name),
    )

  pog.query("INSERT INTO sea.hazard (
       source, source_id, source_episode_id, episode_count,
       hazard_type, hazard_codes, glide,
       alert_level, alert_score, cap_severity,
       severity_value, severity_unit, severity_label, estimate_type,
       title, description, countries, report_url, external_ids,
       onset_at, onset_at_ms, expires_at, expires_at_ms,
       modified_at, modified_at_ms, is_current,
       centroid, bbox, primary_geometry, geometries,
       first_seen_at, last_seen_at,
       subtype, confirmed
     ) VALUES (
       $1, $2, $3, 1,
       'observed_extreme', $4, NULL,
       $5, NULL, $6,
       $7, $8, $9, 'primary',
       $10, $11, '{}', NULL, $12,
       to_timestamp($13::double precision / 1000), $13,
       to_timestamp($14::double precision / 1000), $14,
       to_timestamp($15::double precision / 1000), $15,
       true,
       ST_SetSRID(ST_MakePoint($16, $17), 4326),
       NULL,
       ST_SetSRID(ST_GeomFromGeoJSON($18::text), 4326),
       $19::jsonb,
       to_timestamp($20::double precision / 1000),
       to_timestamp($20::double precision / 1000),
       $21, $22
     )
     ON CONFLICT (source, source_id) DO UPDATE
     SET episode_count = sea.hazard.episode_count + 1,
         severity_value = CASE WHEN EXCLUDED.subtype = 'low_pressure' THEN LEAST(sea.hazard.severity_value, EXCLUDED.severity_value) ELSE GREATEST(sea.hazard.severity_value, EXCLUDED.severity_value) END,
         title = EXCLUDED.title,
         modified_at = to_timestamp(GREATEST(sea.hazard.modified_at_ms, EXCLUDED.modified_at_ms)::double precision / 1000),
         modified_at_ms = GREATEST(sea.hazard.modified_at_ms, EXCLUDED.modified_at_ms),
         expires_at = to_timestamp((GREATEST(sea.hazard.modified_at_ms, EXCLUDED.modified_at_ms) + 10800000)::double precision / 1000),
         expires_at_ms = GREATEST(sea.hazard.modified_at_ms, EXCLUDED.modified_at_ms) + 10800000,
         confirmed = COALESCE(sea.hazard.confirmed, false) OR COALESCE(EXCLUDED.confirmed, false),
         is_current = true,
         last_seen_at = EXCLUDED.last_seen_at
     RETURNING " <> hazard.columns)
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.parameter(pog.nullable(pog.text, Some(int.to_string(obs_time_ms))))
  |> pog.parameter(
    pog.array(pog.text, [
      "wis2:synop",
      "wis2:extreme:" <> subtype,
    ]),
  )
  |> pog.parameter(pog.text(alert_level))
  |> pog.parameter(pog.text(cap_severity))
  |> pog.parameter(pog.nullable(pog.float, Some(value)))
  |> pog.parameter(pog.nullable(pog.text, Some(unit)))
  |> pog.parameter(pog.nullable(pog.text, Some(label)))
  |> pog.parameter(pog.text(title))
  |> pog.parameter(pog.nullable(pog.text, description))
  |> pog.parameter(pog.array(pog.text, ["station:" <> station_id]))
  |> pog.parameter(pog.int(obs_time_ms))
  |> pog.parameter(pog.nullable(pog.int, Some(expires_at_ms)))
  |> pog.parameter(pog.int(obs_time_ms))
  |> pog.parameter(pog.float(lon))
  |> pog.parameter(pog.float(lat))
  |> pog.parameter(pog.nullable(pog.text, Some(primary_geom)))
  |> pog.parameter(pog.nullable(pog.text, Some(geometries)))
  |> pog.parameter(pog.int(now_ms))
  |> pog.parameter(pog.nullable(pog.text, Some(subtype)))
  |> pog.parameter(pog.nullable(pog.bool, Some(confirmed)))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map_error(err)
  |> result.try(fn(x) {
    case x.rows {
      [row] -> Ok(row)
      _ -> Error("hazard insert returned no row for " <> source_id)
    }
  })
}

pub fn extend_observed_extreme_episode(
  source: String,
  source_id: String,
  episode_count: Int,
  value: Float,
  title: String,
  obs_time_ms: Int,
  now_ms: Int,
  confirmed: Bool,
  conn: pog.Connection,
) -> Result(Hazard, String) {
  pog.query("UPDATE sea.hazard
     SET episode_count = $3,
         severity_value = $4,
         title = $5,
         modified_at = to_timestamp(GREATEST(modified_at_ms, $6)::double precision / 1000),
         modified_at_ms = GREATEST(modified_at_ms, $6),
         expires_at = to_timestamp((GREATEST(modified_at_ms, $6) + 10800000)::double precision / 1000),
         expires_at_ms = GREATEST(modified_at_ms, $6) + 10800000,
         confirmed = COALESCE(confirmed, false) OR $7,
         is_current = true,
         last_seen_at = to_timestamp($8::double precision / 1000)
     WHERE source = $1 AND source_id = $2
     RETURNING " <> hazard.columns)
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.parameter(pog.int(episode_count))
  |> pog.parameter(pog.nullable(pog.float, Some(value)))
  |> pog.parameter(pog.text(title))
  |> pog.parameter(pog.int(obs_time_ms))
  |> pog.parameter(pog.nullable(pog.bool, Some(confirmed)))
  |> pog.parameter(pog.int(now_ms))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map_error(err)
  |> result.try(fn(x) {
    case x.rows {
      [row] -> Ok(row)
      _ -> Error("hazard update returned no row for " <> source_id)
    }
  })
}

pub fn end_episode(
  source: String,
  source_id: String,
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Hazard, String) {
  pog.query("UPDATE sea.hazard
     SET is_current = false,
         modified_at = to_timestamp($3::double precision / 1000),
         modified_at_ms = $3,
         last_seen_at = to_timestamp($3::double precision / 1000)
     WHERE source = $1 AND source_id = $2
     RETURNING " <> hazard.columns)
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.parameter(pog.int(now_ms))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map_error(err)
  |> result.try(fn(x) {
    case x.rows {
      [row] -> Ok(row)
      _ -> Error("end_episode returned no row for " <> source_id)
    }
  })
}

pub fn sweep_expired_episodes(
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(Hazard), String) {
  let now_ms = timestamp_to_ms(now)
  pog.query("UPDATE sea.hazard
     SET is_current = false,
         modified_at = to_timestamp($1::double precision / 1000),
         modified_at_ms = $1,
         last_seen_at = to_timestamp($1::double precision / 1000)
     WHERE hazard_type = 'observed_extreme'
       AND is_current
       AND expires_at_ms <= $1
     RETURNING " <> hazard.columns)
  |> pog.parameter(pog.int(now_ms))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

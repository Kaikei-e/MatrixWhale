import domain/alert.{type AlertRow}
import domain/source.{type Source}
import domain/wis2.{
  type AreaPrecision, type BrokerState, type ChannelHealth, BrokerState,
  ChannelHealth,
}
import gleam/dynamic/decode
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
  pog.query("DELETE FROM sea.wis2_notification WHERE received_at < $1")
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
        WHERE cap_sender = $1 AND cap_identifier = $2 AND geom IS NOT NULL
      )
    WHERE (sender = $1 AND identifier = $2) OR source_id = $1 || ',' || $2
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

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}

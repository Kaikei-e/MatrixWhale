import dot_env as dot
import dot_env/env
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import pog
import wisp

pub fn initialize_db() -> pog.Connection {
  dot.load_default()

  let db_host = case env.get_string("POSTGRES_HOST") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_HOST not set")
      panic
    }
  }

  let db_port = case env.get_int("POSTGRES_PORT") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_PORT not set")
      panic
    }
  }

  let db_user = case env.get_string("POSTGRES_USER") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_USER not set")
      panic
    }
  }

  let db_password = case env.get_string("POSTGRES_PASSWORD") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_PASSWORD not set")
      panic
    }
  }

  let db_name = case env.get_string("POSTGRES_DB") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_DB not set")
      panic
    }
  }

  let database_url =
    "postgres://"
    <> db_user
    <> ":"
    <> db_password
    <> "@"
    <> db_host
    <> ":"
    <> int.to_string(db_port)
    <> "/"
    <> db_name

  let pool_name = process.new_name("matrix_whale_db")
  let conf = pog.url_config(pool_name, database_url)
  let config = case conf {
    Ok(config) -> config
    Error(err) -> {
      wisp.log_error("Error creating database config: " <> string.inspect(err))
      panic
    }
  }

  case pog.start(config) {
    Ok(_started) -> Nil
    Error(err) -> {
      wisp.log_error("Error starting database pool: " <> string.inspect(err))
      panic
    }
  }

  let conn = pog.named_connection(pool_name)
  ensure_alert_schema(conn)
  ensure_earthquake_schema(conn)
  conn
}

fn ensure_earthquake_schema(conn: pog.Connection) -> Nil {
  [
    "CREATE TABLE IF NOT EXISTS sea.earthquake (source TEXT NOT NULL, source_id TEXT NOT NULL, contributing_ids TEXT[] NOT NULL DEFAULT '{}', sources TEXT[] NOT NULL DEFAULT '{}', net TEXT, code TEXT, magnitude DOUBLE PRECISION, magnitude_type TEXT, occurred_at TIMESTAMPTZ NOT NULL, occurred_at_ms BIGINT NOT NULL, updated_at TIMESTAMPTZ NOT NULL, updated_at_ms BIGINT NOT NULL, place TEXT, title TEXT, status TEXT, event_type TEXT, tsunami INTEGER, significance INTEGER, alert TEXT, mmi DOUBLE PRECISION, cdi DOUBLE PRECISION, felt INTEGER, nst INTEGER, dmin DOUBLE PRECISION, rms DOUBLE PRECISION, gap DOUBLE PRECISION, url TEXT, detail TEXT, longitude DOUBLE PRECISION NOT NULL, latitude DOUBLE PRECISION NOT NULL, depth_km DOUBLE PRECISION, first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY(source,source_id))",
    "CREATE INDEX IF NOT EXISTS idx_earthquake_occurred_at ON sea.earthquake(occurred_at DESC)",
    "CREATE TABLE IF NOT EXISTS sea.earthquake_revision (source TEXT NOT NULL, source_id TEXT NOT NULL, updated_at_ms BIGINT NOT NULL, recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(), earthquake JSONB NOT NULL, PRIMARY KEY(source,source_id,updated_at_ms))",
    "DO $$ BEGIN ALTER TABLE sea.earthquake_revision ADD CONSTRAINT earthquake_revision_parent_fk FOREIGN KEY(source,source_id) REFERENCES sea.earthquake(source,source_id) ON DELETE CASCADE; EXCEPTION WHEN duplicate_object THEN NULL; END $$",
  ]
  |> list.each(fn(sql) {
    case
      pog.query(sql) |> pog.returning(decode.success(Nil)) |> pog.execute(conn)
    {
      Ok(_) -> Nil
      Error(err) -> {
        wisp.log_error(
          "Error ensuring earthquake schema: " <> string.inspect(err),
        )
        panic
      }
    }
  })
}

// The dev Postgres volume persists across restarts, so `db/init/init.sql`
// only ever runs once. Keep alert schema creation idempotent here too so a
// fresh migration ships without requiring a volume wipe.
fn ensure_alert_schema(conn: pog.Connection) -> Nil {
  [
    "CREATE EXTENSION IF NOT EXISTS pg_trgm",
    "CREATE TABLE IF NOT EXISTS sea.alert (
      id TEXT PRIMARY KEY,
      event TEXT NOT NULL, severity TEXT NOT NULL, urgency TEXT NOT NULL, certainty TEXT NOT NULL,
      message_type TEXT, headline TEXT, area_desc TEXT NOT NULL,
      ugc TEXT[] NOT NULL DEFAULT '{}', same TEXT[] NOT NULL DEFAULT '{}',
      geometry JSONB,
      sent TIMESTAMPTZ, effective TIMESTAMPTZ, expires TIMESTAMPTZ, ends TIMESTAMPTZ,
      first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      ended_at TIMESTAMPTZ
    )",
    "CREATE INDEX IF NOT EXISTS idx_alert_active_expires ON sea.alert (expires) WHERE ended_at IS NULL",
    "CREATE INDEX IF NOT EXISTS idx_alert_ended_at ON sea.alert (ended_at)",
    "CREATE INDEX IF NOT EXISTS idx_alert_severity_active ON sea.alert (severity) WHERE ended_at IS NULL",
    "CREATE INDEX IF NOT EXISTS idx_alert_area_desc_trgm ON sea.alert USING GIN (area_desc gin_trgm_ops)",
    "CREATE INDEX IF NOT EXISTS idx_alert_event_trgm ON sea.alert USING GIN (event gin_trgm_ops)",
  ]
  |> list.each(fn(sql) {
    case
      pog.query(sql)
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)
    {
      Ok(_) -> Nil
      Error(err) -> {
        wisp.log_error("Error ensuring alert schema: " <> string.inspect(err))
        panic
      }
    }
  })
}

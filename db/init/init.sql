CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE DATABASE sea;

\connect sea

CREATE SCHEMA IF NOT EXISTS sea;

CREATE TABLE IF NOT EXISTS sea.severity (
  id SERIAL PRIMARY KEY,
  area_desc TEXT NOT NULL,
  severity VARCHAR(255) NOT NULL,
  datetime TIMESTAMP NOT NULL,

  UNIQUE (area_desc, severity, datetime)
);

CREATE INDEX idx_area_desc ON sea.severity(area_desc);

CREATE INDEX idx_severity_area_desc_datetime ON sea.severity (severity, area_desc, datetime);

CREATE INDEX area_desc_trgm ON sea.severity USING GIN (area_desc gin_trgm_ops);

CREATE INDEX idx_severity_datetime_composite ON sea.severity(datetime DESC, severity) INCLUDE (area_desc);

CREATE TABLE IF NOT EXISTS sea.alert (
  id TEXT PRIMARY KEY,
  event TEXT NOT NULL, severity TEXT NOT NULL, urgency TEXT NOT NULL, certainty TEXT NOT NULL,
  message_type TEXT, headline TEXT, area_desc TEXT NOT NULL,
  ugc TEXT[] NOT NULL DEFAULT '{}', same TEXT[] NOT NULL DEFAULT '{}',
  geometry JSONB,
  sent TIMESTAMPTZ, effective TIMESTAMPTZ, expires TIMESTAMPTZ, ends TIMESTAMPTZ,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_alert_active_expires ON sea.alert (expires) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_alert_ended_at ON sea.alert (ended_at);
CREATE INDEX IF NOT EXISTS idx_alert_severity_active ON sea.alert (severity) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_alert_area_desc_trgm ON sea.alert USING GIN (area_desc gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_alert_event_trgm ON sea.alert USING GIN (event gin_trgm_ops);

CREATE TABLE IF NOT EXISTS sea.earthquake (
  source TEXT NOT NULL, source_id TEXT NOT NULL, contributing_ids TEXT[] NOT NULL DEFAULT '{}', sources TEXT[] NOT NULL DEFAULT '{}',
  net TEXT, code TEXT, magnitude DOUBLE PRECISION, magnitude_type TEXT, occurred_at TIMESTAMPTZ NOT NULL, occurred_at_ms BIGINT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL, updated_at_ms BIGINT NOT NULL, place TEXT, title TEXT, status TEXT, event_type TEXT, tsunami INTEGER, significance INTEGER, alert TEXT,
  mmi DOUBLE PRECISION, cdi DOUBLE PRECISION, felt INTEGER, nst INTEGER, dmin DOUBLE PRECISION, rms DOUBLE PRECISION, gap DOUBLE PRECISION,
  url TEXT, detail TEXT, longitude DOUBLE PRECISION NOT NULL, latitude DOUBLE PRECISION NOT NULL, depth_km DOUBLE PRECISION,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY(source, source_id)
);
CREATE INDEX IF NOT EXISTS idx_earthquake_occurred_at ON sea.earthquake(occurred_at DESC);
CREATE TABLE IF NOT EXISTS sea.earthquake_revision (source TEXT NOT NULL, source_id TEXT NOT NULL, updated_at_ms BIGINT NOT NULL, recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(), earthquake JSONB NOT NULL, PRIMARY KEY(source,source_id,updated_at_ms), CONSTRAINT earthquake_revision_parent_fk FOREIGN KEY(source,source_id) REFERENCES sea.earthquake(source,source_id) ON DELETE CASCADE);

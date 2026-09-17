-- Desired state for the "sea" database, managed by Atlas versioned migrations.
-- pg_trgm is a database-level extension; Atlas Community Edition cannot track
-- it (never appears in generated migrations), so the real, versioned install
-- lives in migrations/..._init.sql. It is repeated here only so `atlas migrate
-- diff`'s dev-database materialization of this file doesn't fail on the
-- gin_trgm_ops indexes below.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS sea;

CREATE TABLE sea.alert (
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
CREATE INDEX idx_alert_active_expires ON sea.alert (expires) WHERE ended_at IS NULL;
CREATE INDEX idx_alert_ended_at ON sea.alert (ended_at);
CREATE INDEX idx_alert_severity_active ON sea.alert (severity) WHERE ended_at IS NULL;
CREATE INDEX idx_alert_area_desc_trgm ON sea.alert USING GIN (area_desc gin_trgm_ops);
CREATE INDEX idx_alert_event_trgm ON sea.alert USING GIN (event gin_trgm_ops);

CREATE TABLE sea.source (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  homepage TEXT,
  license TEXT NOT NULL,
  attribution_text TEXT NOT NULL,
  redistributable BOOLEAN NOT NULL,
  priority INTEGER NOT NULL
);

CREATE TABLE sea.earthquake (
  source TEXT NOT NULL REFERENCES sea.source(id), source_id TEXT NOT NULL, contributing_ids TEXT[] NOT NULL DEFAULT '{}', sources TEXT[] NOT NULL DEFAULT '{}',
  net TEXT, code TEXT, magnitude DOUBLE PRECISION, magnitude_type TEXT, occurred_at TIMESTAMPTZ NOT NULL, occurred_at_ms BIGINT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL, updated_at_ms BIGINT NOT NULL, place TEXT, title TEXT, status TEXT, event_type TEXT, tsunami INTEGER, significance INTEGER, alert TEXT,
  mmi DOUBLE PRECISION, cdi DOUBLE PRECISION, felt INTEGER, nst INTEGER, dmin DOUBLE PRECISION, rms DOUBLE PRECISION, gap DOUBLE PRECISION,
  url TEXT, detail TEXT, longitude DOUBLE PRECISION NOT NULL, latitude DOUBLE PRECISION NOT NULL, depth_km DOUBLE PRECISION,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY(source, source_id)
);
CREATE INDEX idx_earthquake_occurred_at ON sea.earthquake(occurred_at DESC);

CREATE TABLE sea.earthquake_revision (
  source TEXT NOT NULL, source_id TEXT NOT NULL, updated_at_ms BIGINT NOT NULL, recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(), earthquake JSONB NOT NULL,
  PRIMARY KEY(source, source_id, updated_at_ms),
  CONSTRAINT earthquake_revision_parent_fk FOREIGN KEY(source, source_id) REFERENCES sea.earthquake(source, source_id) ON DELETE CASCADE
);

CREATE TABLE sea.event (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind TEXT NOT NULL,
  preferred_source TEXT NOT NULL REFERENCES sea.source(id),
  preferred_source_id TEXT NOT NULL,
  magnitude DOUBLE PRECISION, magnitude_type TEXT,
  occurred_at TIMESTAMPTZ NOT NULL, occurred_at_ms BIGINT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL, updated_at_ms BIGINT NOT NULL,
  place TEXT, title TEXT, status TEXT, event_type TEXT,
  longitude DOUBLE PRECISION NOT NULL, latitude DOUBLE PRECISION NOT NULL, depth_km DOUBLE PRECISION,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_event_occurred_at ON sea.event (occurred_at DESC);
CREATE INDEX idx_event_match_window ON sea.event (occurred_at, latitude, longitude);

CREATE TABLE sea.event_member (
  event_id BIGINT NOT NULL REFERENCES sea.event(id) ON DELETE CASCADE,
  source TEXT NOT NULL, source_id TEXT NOT NULL,
  matched_by TEXT NOT NULL, misfit DOUBLE PRECISION,
  linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (source, source_id),
  FOREIGN KEY (source, source_id) REFERENCES sea.earthquake(source, source_id) ON DELETE CASCADE
);
CREATE INDEX idx_event_member_event ON sea.event_member (event_id);

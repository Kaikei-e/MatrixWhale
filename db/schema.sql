-- Desired state for the "sea" database, managed by Atlas versioned migrations.
-- pg_trgm is a database-level extension; Atlas Community Edition cannot track
-- it (never appears in generated migrations), so the real, versioned install
-- lives in migrations/..._init.sql. It is repeated here only so `atlas migrate
-- diff`'s dev-database materialization of this file doesn't fail on the
-- gin_trgm_ops indexes below.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- postgis is likewise a database-level extension Atlas Community Edition
-- cannot track (never appears in generated migrations), so the real,
-- versioned install lives in migrations/..._gdacs_hazards.sql. It is
-- repeated here only so `atlas migrate diff`'s dev-database materialization
-- of this file doesn't fail on the geometry columns below.
CREATE EXTENSION IF NOT EXISTS postgis;

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
CREATE INDEX idx_alert_first_seen_at ON sea.alert (first_seen_at DESC);

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
CREATE INDEX idx_event_match_window ON sea.event (occurred_at_ms, latitude);
CREATE INDEX idx_event_first_seen_at ON sea.event (first_seen_at DESC, id DESC);

CREATE TABLE sea.event_member (
  event_id BIGINT NOT NULL REFERENCES sea.event(id) ON DELETE CASCADE,
  source TEXT NOT NULL, source_id TEXT NOT NULL,
  matched_by TEXT NOT NULL, misfit DOUBLE PRECISION,
  linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (source, source_id),
  FOREIGN KEY (source, source_id) REFERENCES sea.earthquake(source, source_id) ON DELETE CASCADE
);
CREATE INDEX idx_event_member_event ON sea.event_member (event_id);

CREATE TABLE sea.gdacs_event (
  event_type TEXT NOT NULL,
  event_id BIGINT NOT NULL,
  episode_id BIGINT NOT NULL,
  alert_level TEXT NOT NULL,
  alert_score DOUBLE PRECISION,
  episode_alert_level TEXT,
  episode_alert_score DOUBLE PRECISION,
  name TEXT,
  event_name TEXT,
  description TEXT,
  html_description TEXT,
  country TEXT,
  iso3 TEXT,
  glide TEXT,
  origin_source TEXT,
  origin_source_id TEXT,
  severity_value DOUBLE PRECISION,
  severity_unit TEXT,
  severity_text TEXT,
  from_at TIMESTAMPTZ NOT NULL,
  from_at_ms BIGINT NOT NULL,
  to_at TIMESTAMPTZ,
  to_at_ms BIGINT,
  modified_at TIMESTAMPTZ NOT NULL,
  modified_at_ms BIGINT NOT NULL,
  is_current BOOLEAN NOT NULL,
  is_temporary BOOLEAN NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  latitude DOUBLE PRECISION NOT NULL,
  bbox_west DOUBLE PRECISION,
  bbox_south DOUBLE PRECISION,
  bbox_east DOUBLE PRECISION,
  bbox_north DOUBLE PRECISION,
  affected_countries TEXT[] NOT NULL,
  report_url TEXT,
  geometry_url TEXT,
  icon_url TEXT,
  raw JSONB NOT NULL,
  geometry JSONB,
  geometry_fetched_at TIMESTAMPTZ,
  geometry_http_status INTEGER,
  first_seen_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (event_type, event_id, episode_id)
);
CREATE INDEX idx_gdacs_event_modified_at_ms ON sea.gdacs_event (modified_at_ms);
CREATE INDEX idx_gdacs_event_geometry_pending ON sea.gdacs_event (modified_at_ms DESC) WHERE geometry_fetched_at IS NULL;

CREATE TABLE sea.hazard (
  source TEXT NOT NULL REFERENCES sea.source(id),
  source_id TEXT NOT NULL,
  source_episode_id TEXT,
  episode_count INTEGER NOT NULL,
  hazard_type TEXT NOT NULL,
  hazard_codes TEXT[] NOT NULL,
  glide TEXT,
  alert_level TEXT NOT NULL,
  alert_score DOUBLE PRECISION,
  cap_severity TEXT NOT NULL,
  severity_value DOUBLE PRECISION,
  severity_unit TEXT,
  severity_label TEXT,
  estimate_type TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  countries TEXT[] NOT NULL,
  report_url TEXT,
  external_ids TEXT[] NOT NULL,
  onset_at TIMESTAMPTZ NOT NULL,
  onset_at_ms BIGINT NOT NULL,
  expires_at TIMESTAMPTZ,
  expires_at_ms BIGINT,
  modified_at TIMESTAMPTZ NOT NULL,
  modified_at_ms BIGINT NOT NULL,
  is_current BOOLEAN NOT NULL,
  centroid geometry(Point, 4326) NOT NULL,
  bbox geometry(Polygon, 4326),
  primary_geometry geometry(Geometry, 4326),
  geometries JSONB,
  first_seen_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (source, source_id)
);
CREATE INDEX idx_hazard_modified_at_ms ON sea.hazard (modified_at_ms);
CREATE INDEX idx_hazard_first_seen_at ON sea.hazard (first_seen_at DESC);
CREATE INDEX idx_hazard_type_level ON sea.hazard (hazard_type, alert_level);
CREATE INDEX idx_hazard_centroid ON sea.hazard USING GIST (centroid);
CREATE INDEX idx_hazard_primary_geometry ON sea.hazard USING GIST (primary_geometry);

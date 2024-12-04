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
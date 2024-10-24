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

CREATE INDEX idx_severity_area_desc_datetime ON sea.severity (severity, area_desc, datetime);

CREATE INDEX idx_severity_datetime ON sea.severity(datetime);

CREATE INDEX idx_severity_datetime_severity ON sea.severity(datetime, severity);
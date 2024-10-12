CREATE DATABASE sea;

\connect sea

CREATE SCHEMA IF NOT EXISTS sea;

CREATE TABLE IF NOT EXISTS sea.severity (
  id SERIAL PRIMARY KEY,
  area_desc VARCHAR(255) NOT NULL,
  severity VARCHAR(255) NOT NULL,
  datetime TIMESTAMP NOT NULL,

  UNIQUE (area_desc, severity)
);

CREATE INDEX idx_area_desc_severity_datetime ON sea.severity (area_desc, severity, datetime);

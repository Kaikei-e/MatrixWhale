CREATE SCHEMA IF NOT EXISTS sea;

CREATE TABLE IF NOT EXISTS sea.severity (
  id SERIAL PRIMARY KEY,
  severity VARCHAR(255) NOT NULL,
  datetime TIMESTAMP NOT NULL,

  UNIQUE (severity, datetime)
  INDEX (id, datetime)
);

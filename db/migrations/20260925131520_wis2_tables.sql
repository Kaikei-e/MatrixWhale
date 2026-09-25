-- Create "wis2_broker" table
CREATE TABLE "sea"."wis2_broker" (
  "id" smallint NOT NULL,
  "url" text NOT NULL,
  "connected" boolean NOT NULL,
  "error" text NULL,
  "last_report_at" timestamptz NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "wis2_broker_id_check" CHECK (id = 1)
);
-- Create "wis2_cap_area" table
CREATE TABLE "sea"."wis2_cap_area" (
  "cap_sender" text NOT NULL,
  "cap_identifier" text NOT NULL,
  "area_key" text NOT NULL,
  "geom" public.geometry(MultiPolygon,4326) NULL,
  "received_at" timestamptz NOT NULL,
  PRIMARY KEY ("cap_sender", "cap_identifier", "area_key")
);
-- Create index "idx_wis2_cap_area_geom" to table: "wis2_cap_area"
CREATE INDEX "idx_wis2_cap_area_geom" ON "sea"."wis2_cap_area" USING gist ("geom");
-- Create "wis2_health_bucket" table
CREATE TABLE "sea"."wis2_health_bucket" (
  "centre_id" text NOT NULL,
  "kind" text NOT NULL,
  "bucket_start" timestamptz NOT NULL,
  "received" integer NOT NULL DEFAULT 0,
  "duplicates" integer NOT NULL DEFAULT 0,
  "download_failed" integer NOT NULL DEFAULT 0,
  "decode_failed" integer NOT NULL DEFAULT 0,
  "integrity_failed" integer NOT NULL DEFAULT 0,
  "last_received_at" timestamptz NULL,
  PRIMARY KEY ("centre_id", "kind", "bucket_start")
);
-- Create "wis2_notification" table
CREATE TABLE "sea"."wis2_notification" (
  "data_id" text NOT NULL,
  "notification_id" text NULL,
  "centre_id" text NULL,
  "kind" text NULL,
  "topic" text NULL,
  "channel" text NULL,
  "pubtime" timestamptz NULL,
  "received_at" timestamptz NULL,
  "fetched_via" text NULL,
  "download_url" text NULL,
  "cap_sender" text NULL,
  "cap_identifier" text NULL,
  "outcome" text NOT NULL,
  PRIMARY KEY ("data_id")
);
-- Create index "idx_wis2_notification_received_at" to table: "wis2_notification"
CREATE INDEX "idx_wis2_notification_received_at" ON "sea"."wis2_notification" ("received_at" DESC);

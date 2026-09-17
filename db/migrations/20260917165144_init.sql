-- Atlas cannot manage extensions without a Pro login, so pg_trgm is created
-- here as plain SQL instead of through db/schema.sql.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- Add new schema named "sea"
CREATE SCHEMA "sea";
-- Create "alert" table
CREATE TABLE "sea"."alert" (
  "id" text NOT NULL,
  "event" text NOT NULL,
  "severity" text NOT NULL,
  "urgency" text NOT NULL,
  "certainty" text NOT NULL,
  "message_type" text NULL,
  "headline" text NULL,
  "area_desc" text NOT NULL,
  "ugc" text[] NOT NULL DEFAULT '{}',
  "same" text[] NOT NULL DEFAULT '{}',
  "geometry" jsonb NULL,
  "sent" timestamptz NULL,
  "effective" timestamptz NULL,
  "expires" timestamptz NULL,
  "ends" timestamptz NULL,
  "first_seen_at" timestamptz NOT NULL DEFAULT now(),
  "last_seen_at" timestamptz NOT NULL DEFAULT now(),
  "ended_at" timestamptz NULL,
  PRIMARY KEY ("id")
);
-- Create index "idx_alert_active_expires" to table: "alert"
CREATE INDEX "idx_alert_active_expires" ON "sea"."alert" ("expires") WHERE (ended_at IS NULL);
-- Create index "idx_alert_area_desc_trgm" to table: "alert"
CREATE INDEX "idx_alert_area_desc_trgm" ON "sea"."alert" USING gin ("area_desc" gin_trgm_ops);
-- Create index "idx_alert_ended_at" to table: "alert"
CREATE INDEX "idx_alert_ended_at" ON "sea"."alert" ("ended_at");
-- Create index "idx_alert_event_trgm" to table: "alert"
CREATE INDEX "idx_alert_event_trgm" ON "sea"."alert" USING gin ("event" gin_trgm_ops);
-- Create index "idx_alert_severity_active" to table: "alert"
CREATE INDEX "idx_alert_severity_active" ON "sea"."alert" ("severity") WHERE (ended_at IS NULL);
-- Create "earthquake" table
CREATE TABLE "sea"."earthquake" (
  "source" text NOT NULL,
  "source_id" text NOT NULL,
  "contributing_ids" text[] NOT NULL DEFAULT '{}',
  "sources" text[] NOT NULL DEFAULT '{}',
  "net" text NULL,
  "code" text NULL,
  "magnitude" double precision NULL,
  "magnitude_type" text NULL,
  "occurred_at" timestamptz NOT NULL,
  "occurred_at_ms" bigint NOT NULL,
  "updated_at" timestamptz NOT NULL,
  "updated_at_ms" bigint NOT NULL,
  "place" text NULL,
  "title" text NULL,
  "status" text NULL,
  "event_type" text NULL,
  "tsunami" integer NULL,
  "significance" integer NULL,
  "alert" text NULL,
  "mmi" double precision NULL,
  "cdi" double precision NULL,
  "felt" integer NULL,
  "nst" integer NULL,
  "dmin" double precision NULL,
  "rms" double precision NULL,
  "gap" double precision NULL,
  "url" text NULL,
  "detail" text NULL,
  "longitude" double precision NOT NULL,
  "latitude" double precision NOT NULL,
  "depth_km" double precision NULL,
  "first_seen_at" timestamptz NOT NULL DEFAULT now(),
  "last_seen_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("source", "source_id")
);
-- Create index "idx_earthquake_occurred_at" to table: "earthquake"
CREATE INDEX "idx_earthquake_occurred_at" ON "sea"."earthquake" ("occurred_at" DESC);
-- Create "source" table
CREATE TABLE "sea"."source" (
  "id" text NOT NULL,
  "name" text NOT NULL,
  "homepage" text NULL,
  "license" text NOT NULL,
  "attribution_text" text NOT NULL,
  "redistributable" boolean NOT NULL,
  "priority" integer NOT NULL,
  PRIMARY KEY ("id")
);
-- Create "earthquake_revision" table
CREATE TABLE "sea"."earthquake_revision" (
  "source" text NOT NULL,
  "source_id" text NOT NULL,
  "updated_at_ms" bigint NOT NULL,
  "recorded_at" timestamptz NOT NULL DEFAULT now(),
  "earthquake" jsonb NOT NULL,
  PRIMARY KEY ("source", "source_id", "updated_at_ms"),
  CONSTRAINT "earthquake_revision_parent_fk" FOREIGN KEY ("source", "source_id") REFERENCES "sea"."earthquake" ("source", "source_id") ON UPDATE NO ACTION ON DELETE CASCADE
);

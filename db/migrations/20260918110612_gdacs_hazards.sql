-- Atlas cannot manage extensions without a Pro login, so postgis is created
-- here as plain SQL instead of through db/schema.sql.
CREATE EXTENSION IF NOT EXISTS postgis;
-- Create "gdacs_event" table
CREATE TABLE "sea"."gdacs_event" (
  "event_type" text NOT NULL,
  "event_id" bigint NOT NULL,
  "episode_id" bigint NOT NULL,
  "alert_level" text NOT NULL,
  "alert_score" double precision NULL,
  "episode_alert_level" text NULL,
  "episode_alert_score" double precision NULL,
  "name" text NULL,
  "event_name" text NULL,
  "description" text NULL,
  "html_description" text NULL,
  "country" text NULL,
  "iso3" text NULL,
  "glide" text NULL,
  "origin_source" text NULL,
  "origin_source_id" text NULL,
  "severity_value" double precision NULL,
  "severity_unit" text NULL,
  "severity_text" text NULL,
  "from_at" timestamptz NOT NULL,
  "from_at_ms" bigint NOT NULL,
  "to_at" timestamptz NULL,
  "to_at_ms" bigint NULL,
  "modified_at" timestamptz NOT NULL,
  "modified_at_ms" bigint NOT NULL,
  "is_current" boolean NOT NULL,
  "is_temporary" boolean NOT NULL,
  "longitude" double precision NOT NULL,
  "latitude" double precision NOT NULL,
  "bbox_west" double precision NULL,
  "bbox_south" double precision NULL,
  "bbox_east" double precision NULL,
  "bbox_north" double precision NULL,
  "affected_countries" text[] NOT NULL,
  "report_url" text NULL,
  "geometry_url" text NULL,
  "icon_url" text NULL,
  "raw" jsonb NOT NULL,
  "geometry" jsonb NULL,
  "geometry_fetched_at" timestamptz NULL,
  "geometry_http_status" integer NULL,
  "first_seen_at" timestamptz NOT NULL,
  "last_seen_at" timestamptz NOT NULL,
  PRIMARY KEY ("event_type", "event_id", "episode_id")
);
-- Create index "idx_gdacs_event_geometry_pending" to table: "gdacs_event"
CREATE INDEX "idx_gdacs_event_geometry_pending" ON "sea"."gdacs_event" ("modified_at_ms" DESC) WHERE (geometry_fetched_at IS NULL);
-- Create index "idx_gdacs_event_modified_at_ms" to table: "gdacs_event"
CREATE INDEX "idx_gdacs_event_modified_at_ms" ON "sea"."gdacs_event" ("modified_at_ms");
-- Create "hazard" table
CREATE TABLE "sea"."hazard" (
  "source" text NOT NULL,
  "source_id" text NOT NULL,
  "source_episode_id" text NULL,
  "episode_count" integer NOT NULL,
  "hazard_type" text NOT NULL,
  "hazard_codes" text[] NOT NULL,
  "glide" text NULL,
  "alert_level" text NOT NULL,
  "alert_score" double precision NULL,
  "cap_severity" text NOT NULL,
  "severity_value" double precision NULL,
  "severity_unit" text NULL,
  "severity_label" text NULL,
  "estimate_type" text NOT NULL,
  "title" text NOT NULL,
  "description" text NULL,
  "countries" text[] NOT NULL,
  "report_url" text NULL,
  "external_ids" text[] NOT NULL,
  "onset_at" timestamptz NOT NULL,
  "onset_at_ms" bigint NOT NULL,
  "expires_at" timestamptz NULL,
  "expires_at_ms" bigint NULL,
  "modified_at" timestamptz NOT NULL,
  "modified_at_ms" bigint NOT NULL,
  "is_current" boolean NOT NULL,
  "centroid" public.geometry(Point,4326) NOT NULL,
  "bbox" public.geometry(Polygon,4326) NULL,
  "primary_geometry" public.geometry(Geometry,4326) NULL,
  "geometries" jsonb NULL,
  "first_seen_at" timestamptz NOT NULL,
  "last_seen_at" timestamptz NOT NULL,
  PRIMARY KEY ("source", "source_id"),
  CONSTRAINT "hazard_source_fkey" FOREIGN KEY ("source") REFERENCES "sea"."source" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
-- Create index "idx_hazard_centroid" to table: "hazard"
CREATE INDEX "idx_hazard_centroid" ON "sea"."hazard" USING gist ("centroid");
-- Create index "idx_hazard_modified_at_ms" to table: "hazard"
CREATE INDEX "idx_hazard_modified_at_ms" ON "sea"."hazard" ("modified_at_ms");
-- Create index "idx_hazard_primary_geometry" to table: "hazard"
CREATE INDEX "idx_hazard_primary_geometry" ON "sea"."hazard" USING gist ("primary_geometry");
-- Create index "idx_hazard_type_level" to table: "hazard"
CREATE INDEX "idx_hazard_type_level" ON "sea"."hazard" ("hazard_type", "alert_level");

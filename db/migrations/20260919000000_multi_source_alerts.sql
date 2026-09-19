-- Insert NOAA source row first so foreign key constraints hold
INSERT INTO "sea"."source" ("id", "name", "homepage", "license", "attribution_text", "redistributable", "priority")
VALUES ('noaa', 'NOAA National Weather Service', 'https://www.weather.gov/', 'public-domain', 'Source: NOAA National Weather Service', true, 100)
ON CONFLICT ("id") DO NOTHING;

-- Rename old alert table and drop old indexes/constraints to prevent name collisions
ALTER TABLE "sea"."alert" RENAME TO "alert_old";
DROP INDEX IF EXISTS "sea"."idx_alert_active_expires";
DROP INDEX IF EXISTS "sea"."idx_alert_area_desc_trgm";
DROP INDEX IF EXISTS "sea"."idx_alert_ended_at";
DROP INDEX IF EXISTS "sea"."idx_alert_event_trgm";
DROP INDEX IF EXISTS "sea"."idx_alert_severity_active";
DROP INDEX IF EXISTS "sea"."idx_alert_first_seen_at";
ALTER TABLE "sea"."alert_old" DROP CONSTRAINT IF EXISTS "alert_pkey";

-- Create new multi-source "alert" table
CREATE TABLE "sea"."alert" (
  "source" text NOT NULL,
  "source_id" text NOT NULL,
  "sender" text NULL,
  "sender_name" text NULL,
  "identifier" text NULL,
  "message_type" text NULL,
  "event" text NOT NULL,
  "category" text[] NOT NULL DEFAULT '{}',
  "severity" text NOT NULL,
  "urgency" text NOT NULL,
  "certainty" text NOT NULL,
  "headline" text NULL,
  "description" text NULL,
  "instruction" text NULL,
  "web" text NULL,
  "contact" text NULL,
  "language" text NULL,
  "area_desc" text NOT NULL,
  "geocodes" jsonb NOT NULL DEFAULT '[]',
  "countries" text[] NOT NULL DEFAULT '{}',
  "geom" public.geometry(MultiPolygon, 4326) NULL,
  "reference_keys" text[] NOT NULL DEFAULT '{}',
  "sent" timestamptz NULL,
  "effective" timestamptz NULL,
  "onset" timestamptz NULL,
  "expires" timestamptz NULL,
  "ends" timestamptz NULL,
  "active_until" timestamptz NOT NULL,
  "first_seen_at" timestamptz NOT NULL DEFAULT now(),
  "last_seen_at" timestamptz NOT NULL DEFAULT now(),
  "ended_at" timestamptz NULL,
  "end_reason" text NULL,
  "superseded_by" text NULL,
  PRIMARY KEY ("source", "source_id"),
  CONSTRAINT "alert_source_fkey" FOREIGN KEY ("source") REFERENCES "sea"."source" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
CREATE INDEX "idx_alert_first_seen_at" ON "sea"."alert" ("first_seen_at" DESC);
CREATE INDEX "idx_alert_active_until" ON "sea"."alert" ("active_until") WHERE (ended_at IS NULL);
CREATE INDEX "idx_alert_ended_at" ON "sea"."alert" ("ended_at");
CREATE INDEX "idx_alert_geom" ON "sea"."alert" USING gist ("geom");
CREATE INDEX "idx_alert_reference_keys" ON "sea"."alert" USING gin ("reference_keys");
CREATE INDEX "idx_alert_area_desc_trgm" ON "sea"."alert" USING gin ("area_desc" gin_trgm_ops);
CREATE INDEX "idx_alert_event_trgm" ON "sea"."alert" USING gin ("event" gin_trgm_ops);
CREATE INDEX "idx_alert_headline_trgm" ON "sea"."alert" USING gin ("headline" gin_trgm_ops);

-- Create CAP tables
CREATE TABLE "sea"."cap_authority" (
  "oid" text NOT NULL,
  "source" text NOT NULL,
  "name" text NOT NULL,
  "country_name" text NOT NULL,
  "country_iso3" text NOT NULL,
  "abbrev" text NULL,
  "register_url" text NULL,
  "categories" text[] NOT NULL DEFAULT '{}',
  "raa_pub_date" timestamptz NULL,
  "first_seen_at" timestamptz NOT NULL,
  "last_seen_at" timestamptz NOT NULL,
  "removed_at" timestamptz NULL,
  PRIMARY KEY ("oid"),
  CONSTRAINT "cap_authority_source_fkey" FOREIGN KEY ("source") REFERENCES "sea"."source" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION
);

CREATE TABLE "sea"."cap_feed" (
  "url" text NOT NULL,
  "authority_oid" text NOT NULL,
  "authority_oids" text[] NOT NULL,
  "language" text NULL,
  "subscribed" boolean NOT NULL,
  "exclusion_reason" text NULL,
  "format" text NULL,
  "last_polled_at" timestamptz NULL,
  "last_success_at" timestamptz NULL,
  "last_http_status" integer NULL,
  "last_error" text NULL,
  "consecutive_failures" integer NOT NULL DEFAULT 0,
  "item_count" integer NULL,
  "newest_item_at" timestamptz NULL,
  "first_seen_at" timestamptz NOT NULL,
  "last_seen_at" timestamptz NOT NULL,
  PRIMARY KEY ("url"),
  CONSTRAINT "cap_feed_authority_oid_fkey" FOREIGN KEY ("authority_oid") REFERENCES "sea"."cap_authority" ("oid") ON UPDATE NO ACTION ON DELETE NO ACTION
);

CREATE TABLE "sea"."cap_item" (
  "cap_url" text NOT NULL,
  "feed_url" text NOT NULL,
  "published_at" timestamptz NULL,
  "state" text NOT NULL,
  "attempts" integer NOT NULL DEFAULT 0,
  "last_attempt_at" timestamptz NULL,
  "http_status" integer NULL,
  "error" text NULL,
  "message_key" text NULL,
  "first_seen_at" timestamptz NOT NULL,
  "last_seen_at" timestamptz NOT NULL,
  PRIMARY KEY ("cap_url"),
  CONSTRAINT "cap_item_feed_url_fkey" FOREIGN KEY ("feed_url") REFERENCES "sea"."cap_feed" ("url") ON UPDATE NO ACTION ON DELETE NO ACTION
);
CREATE INDEX "idx_cap_item_state_first_seen" ON "sea"."cap_item" ("state", "first_seen_at" DESC);

CREATE TABLE "sea"."cap_message" (
  "sender" text NOT NULL,
  "identifier" text NOT NULL,
  "sent" timestamptz NOT NULL,
  "sent_ms" bigint NOT NULL,
  "status" text NOT NULL,
  "msg_type" text NOT NULL,
  "scope" text NOT NULL,
  "source" text NOT NULL,
  "feed_url" text NOT NULL,
  "cap_url" text NOT NULL,
  "reference_keys" text[] NOT NULL DEFAULT '{}',
  "cap" jsonb NOT NULL,
  "raw_xml" text NOT NULL,
  "normalized" boolean NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "first_seen_at" timestamptz NOT NULL,
  "last_seen_at" timestamptz NOT NULL,
  PRIMARY KEY ("sender", "identifier"),
  CONSTRAINT "cap_message_source_fkey" FOREIGN KEY ("source") REFERENCES "sea"."source" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
CREATE INDEX "idx_cap_message_reference_keys" ON "sea"."cap_message" USING gin ("reference_keys");
CREATE INDEX "idx_cap_message_expires_at" ON "sea"."cap_message" ("expires_at");

-- Copy existing NOAA rows from alert_old to alert
INSERT INTO "sea"."alert" (
  "source", "source_id", "sender", "sender_name", "identifier", "message_type",
  "event", "category", "severity", "urgency", "certainty", "headline",
  "description", "instruction", "web", "contact", "language", "area_desc",
  "geocodes", "countries", "geom", "reference_keys", "sent", "effective",
  "onset", "expires", "ends", "active_until", "first_seen_at", "last_seen_at",
  "ended_at", "end_reason", "superseded_by"
)
SELECT
  'noaa' AS "source",
  "id" AS "source_id",
  NULL AS "sender",
  NULL AS "sender_name",
  NULL AS "identifier",
  "message_type",
  "event",
  '{}'::text[] AS "category",
  "severity",
  "urgency",
  "certainty",
  "headline",
  NULL AS "description",
  NULL AS "instruction",
  NULL AS "web",
  NULL AS "contact",
  'en-US' AS "language",
  "area_desc",
  COALESCE((
    SELECT jsonb_agg(jsonb_build_object('name', 'UGC', 'value', u))
    FROM unnest("ugc") AS u
  ), '[]'::jsonb) || COALESCE((
    SELECT jsonb_agg(jsonb_build_object('name', 'SAME', 'value', s))
    FROM unnest("same") AS s
  ), '[]'::jsonb) AS "geocodes",
  ARRAY['USA']::text[] AS "countries",
  CASE
    WHEN jsonb_typeof("geometry") = 'object' THEN
      ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON("geometry"::text), 4326)), 3))
    ELSE NULL
  END AS "geom",
  '{}'::text[] AS "reference_keys",
  "sent",
  "effective",
  NULL AS "onset",
  "expires",
  "ends",
  COALESCE("ends", "expires", "sent" + interval '24 hours', "first_seen_at" + interval '24 hours') AS "active_until",
  "first_seen_at",
  "last_seen_at",
  "ended_at",
  CASE WHEN "ended_at" IS NOT NULL THEN 'withdrawn' ELSE NULL END AS "end_reason",
  NULL AS "superseded_by"
FROM "sea"."alert_old";

-- Drop old table
DROP TABLE "sea"."alert_old";

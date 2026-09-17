-- Create "event" table
CREATE TABLE "sea"."event" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "kind" text NOT NULL,
  "preferred_source" text NOT NULL,
  "preferred_source_id" text NOT NULL,
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
  "longitude" double precision NOT NULL,
  "latitude" double precision NOT NULL,
  "depth_km" double precision NULL,
  "first_seen_at" timestamptz NOT NULL DEFAULT now(),
  "last_seen_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "event_preferred_source_fkey" FOREIGN KEY ("preferred_source") REFERENCES "sea"."source" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
-- Create index "idx_event_match_window" to table: "event"
CREATE INDEX "idx_event_match_window" ON "sea"."event" ("occurred_at", "latitude", "longitude");
-- Create index "idx_event_occurred_at" to table: "event"
CREATE INDEX "idx_event_occurred_at" ON "sea"."event" ("occurred_at" DESC);
-- Create "event_member" table
CREATE TABLE "sea"."event_member" (
  "event_id" bigint NOT NULL,
  "source" text NOT NULL,
  "source_id" text NOT NULL,
  "matched_by" text NOT NULL,
  "misfit" double precision NULL,
  "linked_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("source", "source_id"),
  CONSTRAINT "event_member_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "sea"."event" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "event_member_source_source_id_fkey" FOREIGN KEY ("source", "source_id") REFERENCES "sea"."earthquake" ("source", "source_id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_event_member_event" to table: "event_member"
CREATE INDEX "idx_event_member_event" ON "sea"."event_member" ("event_id");

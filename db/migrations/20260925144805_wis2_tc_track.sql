-- Create "wis2_tc_track" table
CREATE TABLE "sea"."wis2_tc_track" (
  "source" text NOT NULL,
  "storm_id" text NOT NULL,
  "analysis_time" timestamptz NOT NULL,
  "storm_name" text NULL,
  "centre_id" text NOT NULL,
  "data_id" text NOT NULL,
  "originating_centre" integer NOT NULL,
  "ensemble_member" integer NULL,
  "points" jsonb NOT NULL,
  "track" public.geometry(LineString,4326) NULL,
  "matched_hazard_source" text NULL,
  "matched_hazard_source_id" text NULL,
  "received_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("source", "storm_id", "analysis_time"),
  CONSTRAINT "wis2_tc_track_source_fkey" FOREIGN KEY ("source") REFERENCES "sea"."source" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION
);
-- Create index "idx_wis2_tc_track_latest" to table: "wis2_tc_track"
CREATE INDEX "idx_wis2_tc_track_latest" ON "sea"."wis2_tc_track" ("source", "storm_id", "analysis_time" DESC);
-- Create index "idx_wis2_tc_track_matched_hazard" to table: "wis2_tc_track"
CREATE INDEX "idx_wis2_tc_track_matched_hazard" ON "sea"."wis2_tc_track" ("matched_hazard_source", "matched_hazard_source_id");
-- Create index "idx_wis2_tc_track_received_at" to table: "wis2_tc_track"
CREATE INDEX "idx_wis2_tc_track_received_at" ON "sea"."wis2_tc_track" ("received_at");

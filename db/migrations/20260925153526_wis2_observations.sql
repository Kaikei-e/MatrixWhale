-- Modify "hazard" table
ALTER TABLE "sea"."hazard" ADD COLUMN "subtype" text NULL, ADD COLUMN "confirmed" boolean NULL;
-- Create "wis2_station" table
CREATE TABLE "sea"."wis2_station" (
  "station_id" text NOT NULL,
  "name" text NULL,
  "lat" double precision NOT NULL,
  "lon" double precision NOT NULL,
  "elevation_m" double precision NULL,
  "geom" public.geometry(Point,4326) NOT NULL,
  "last_observed_at" timestamptz NOT NULL,
  "wind_speed_ms" double precision NULL,
  "wind_observed_at" timestamptz NULL,
  "gust_ms" double precision NULL,
  "gust_observed_at" timestamptz NULL,
  "precip_1h_mm" double precision NULL,
  "precip_1h_observed_at" timestamptz NULL,
  "precip_24h_mm" double precision NULL,
  "precip_24h_observed_at" timestamptz NULL,
  "mslp_hpa" double precision NULL,
  "mslp_observed_at" timestamptz NULL,
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("station_id")
);
-- Create index "idx_wis2_station_geom" to table: "wis2_station"
CREATE INDEX "idx_wis2_station_geom" ON "sea"."wis2_station" USING gist ("geom");

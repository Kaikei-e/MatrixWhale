-- Create "jma_area" table
CREATE TABLE "sea"."jma_area" (
  "code" text NOT NULL,
  "name" text NOT NULL,
  "geom" public.geometry(MultiPolygon,4326) NOT NULL,
  PRIMARY KEY ("code")
);
-- Create index "idx_jma_area_geom" to table: "jma_area"
CREATE INDEX "idx_jma_area_geom" ON "sea"."jma_area" USING gist ("geom");

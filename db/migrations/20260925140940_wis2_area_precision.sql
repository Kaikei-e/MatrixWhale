-- Modify "wis2_cap_area" table
ALTER TABLE "sea"."wis2_cap_area" ADD CONSTRAINT "wis2_cap_area_precision_check" CHECK ("precision" = ANY (ARRAY['exact'::text, 'bbox'::text])), ADD COLUMN "precision" text NOT NULL DEFAULT 'exact';

-- Modify "earthquake" table
ALTER TABLE "sea"."earthquake" ADD CONSTRAINT "earthquake_source_fkey" FOREIGN KEY ("source") REFERENCES "sea"."source" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION;

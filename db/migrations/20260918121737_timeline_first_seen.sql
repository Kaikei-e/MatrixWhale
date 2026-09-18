-- Create index "idx_alert_first_seen_at" to table: "alert"
CREATE INDEX "idx_alert_first_seen_at" ON "sea"."alert" ("first_seen_at" DESC);
-- Create index "idx_event_first_seen_at" to table: "event"
CREATE INDEX "idx_event_first_seen_at" ON "sea"."event" ("first_seen_at" DESC, "id" DESC);
-- Create index "idx_hazard_first_seen_at" to table: "hazard"
CREATE INDEX "idx_hazard_first_seen_at" ON "sea"."hazard" ("first_seen_at" DESC);

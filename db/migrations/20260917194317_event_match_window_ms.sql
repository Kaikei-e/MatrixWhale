-- Drop index "idx_event_match_window" from table: "event"
DROP INDEX "sea"."idx_event_match_window";
-- Create index "idx_event_match_window" to table: "event"
CREATE INDEX "idx_event_match_window" ON "sea"."event" ("occurred_at_ms", "latitude");

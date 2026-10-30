-- Create index "idx_alert_sender_identifier" to table: "alert"
CREATE INDEX "idx_alert_sender_identifier" ON "sea"."alert" ("sender", "identifier") WHERE ((sender IS NOT NULL) AND (identifier IS NOT NULL));
-- Create index "idx_alert_source_id" to table: "alert"
CREATE INDEX "idx_alert_source_id" ON "sea"."alert" ("source_id");
-- Create index "idx_cap_item_pending_retry" to table: "cap_item"
CREATE INDEX "idx_cap_item_pending_retry" ON "sea"."cap_item" ("first_seen_at" DESC) WHERE (state = ANY (ARRAY['pending'::text, 'failed'::text]));
-- Create index "idx_cap_item_failed_feed_url" to table: "cap_item"
CREATE INDEX "idx_cap_item_failed_feed_url" ON "sea"."cap_item" ("feed_url") WHERE (state = 'failed'::text);
-- Create index "idx_cap_item_last_seen_at" to table: "cap_item"
CREATE INDEX "idx_cap_item_last_seen_at" ON "sea"."cap_item" ("last_seen_at") WHERE (state <> 'pending'::text);
-- Create index "idx_jma_item_pending_retry" to table: "jma_item"
CREATE INDEX "idx_jma_item_pending_retry" ON "sea"."jma_item" ("published_at" DESC NULLS LAST, "first_seen_at" DESC) WHERE (state = ANY (ARRAY['pending'::text, 'failed'::text]));
-- Create index "idx_jma_item_last_seen_at" to table: "jma_item"
CREATE INDEX "idx_jma_item_last_seen_at" ON "sea"."jma_item" ("last_seen_at") WHERE (state <> 'pending'::text);
-- Create index "idx_wis2_cap_area_received_at" to table: "wis2_cap_area"
CREATE INDEX "idx_wis2_cap_area_received_at" ON "sea"."wis2_cap_area" ("received_at");
-- Create index "idx_wis2_health_bucket_start" to table: "wis2_health_bucket"
CREATE INDEX "idx_wis2_health_bucket_start" ON "sea"."wis2_health_bucket" ("bucket_start");
-- Create index "idx_wis2_station_geog" to table: "wis2_station"
CREATE INDEX "idx_wis2_station_geog" ON "sea"."wis2_station" USING gist (((geom)::geography));

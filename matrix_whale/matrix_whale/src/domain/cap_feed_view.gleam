import gleam/json
import gleam/option.{type Option}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

pub type CapAuthorityView {
  CapAuthorityView(
    oid: String,
    source: String,
    name: String,
    country_name: String,
    country_iso3: String,
  )
}

pub type CapFeedView {
  CapFeedView(
    url: String,
    health: String,
    authority: CapAuthorityView,
    authority_oids: List(String),
    language: Option(String),
    subscribed: Bool,
    exclusion_reason: Option(String),
    format: Option(String),
    last_polled_at: Option(Timestamp),
    last_success_at: Option(Timestamp),
    last_http_status: Option(Int),
    last_error: Option(String),
    consecutive_failures: Int,
    item_count: Option(Int),
    newest_item_at: Option(Timestamp),
    active_alerts: Int,
    failed_items: Int,
  )
}

pub type CapHealthCounts {
  CapHealthCounts(
    ok: Int,
    empty: Int,
    stale: Int,
    degraded: Int,
    failing: Int,
    pending: Int,
    excluded: Int,
  )
}

pub type CapFeedsView {
  CapFeedsView(
    generated_at: Timestamp,
    registry_fetched_at: Option(Timestamp),
    counts: CapHealthCounts,
    feeds: List(CapFeedView),
  )
}

pub fn to_json(view: CapFeedsView) -> json.Json {
  json.object([
    #("generated_at", json.string(timestamp_to_rfc3339(view.generated_at))),
    #(
      "registry_fetched_at",
      json.nullable(view.registry_fetched_at, fn(t) {
        json.string(timestamp_to_rfc3339(t))
      }),
    ),
    #("counts", health_counts_to_json(view.counts)),
    #("feeds", json.array(view.feeds, feed_to_json)),
  ])
}

pub fn feed_to_json(f: CapFeedView) -> json.Json {
  json.object([
    #("url", json.string(f.url)),
    #("health", json.string(f.health)),
    #("authority", authority_to_json(f.authority)),
    #("authority_oids", json.array(f.authority_oids, json.string)),
    #("language", json.nullable(f.language, json.string)),
    #("subscribed", json.bool(f.subscribed)),
    #("exclusion_reason", json.nullable(f.exclusion_reason, json.string)),
    #("format", json.nullable(f.format, json.string)),
    #(
      "last_polled_at",
      json.nullable(f.last_polled_at, fn(t) {
        json.string(timestamp_to_rfc3339(t))
      }),
    ),
    #(
      "last_success_at",
      json.nullable(f.last_success_at, fn(t) {
        json.string(timestamp_to_rfc3339(t))
      }),
    ),
    #("last_http_status", json.nullable(f.last_http_status, json.int)),
    #("last_error", json.nullable(f.last_error, json.string)),
    #("consecutive_failures", json.int(f.consecutive_failures)),
    #("item_count", json.nullable(f.item_count, json.int)),
    #(
      "newest_item_at",
      json.nullable(f.newest_item_at, fn(t) {
        json.string(timestamp_to_rfc3339(t))
      }),
    ),
    #("active_alerts", json.int(f.active_alerts)),
    #("failed_items", json.int(f.failed_items)),
  ])
}

pub fn health_counts_to_json(c: CapHealthCounts) -> json.Json {
  json.object([
    #("ok", json.int(c.ok)),
    #("empty", json.int(c.empty)),
    #("stale", json.int(c.stale)),
    #("degraded", json.int(c.degraded)),
    #("failing", json.int(c.failing)),
    #("pending", json.int(c.pending)),
    #("excluded", json.int(c.excluded)),
  ])
}

pub fn authority_to_json(a: CapAuthorityView) -> json.Json {
  json.object([
    #("oid", json.string(a.oid)),
    #("source", json.string(a.source)),
    #("name", json.string(a.name)),
    #("country_name", json.string(a.country_name)),
    #("country_iso3", json.string(a.country_iso3)),
  ])
}

fn timestamp_to_rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}

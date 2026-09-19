import domain/alert
import domain/cap_feed_view.{
  type CapFeedsView, CapAuthorityView, CapFeedView, CapFeedsView,
  CapHealthCounts,
}
import domain/raa
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import pog

pub type SubscribedFeed {
  SubscribedFeed(url: String, poll_interval_seconds: Int)
}

pub fn list_subscribed(
  conn: pog.Connection,
) -> Result(List(SubscribedFeed), String) {
  pog.query(
    "SELECT url, consecutive_failures FROM sea.cap_feed WHERE subscribed = true ORDER BY url ASC",
  )
  |> pog.returning(subscribed_feed_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn subscribed_feed_decoder() -> decode.Decoder(SubscribedFeed) {
  use url <- decode.field(0, decode.string)
  use consecutive_failures <- decode.field(1, decode.int)
  decode.success(SubscribedFeed(
    url:,
    poll_interval_seconds: raa.poll_interval_seconds(consecutive_failures),
  ))
}

type FeedRow {
  FeedRow(
    url: String,
    authority_oid: String,
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
    authority_source: String,
    authority_name: String,
    authority_country_name: String,
    authority_country_iso3: String,
    active_alerts: Option(Int),
    failed_items: Option(Int),
  )
}

fn feed_row_decoder() -> decode.Decoder(FeedRow) {
  use url <- decode.field(0, decode.string)
  use authority_oid <- decode.field(1, decode.string)
  use authority_oids <- decode.field(2, decode.list(decode.string))
  use language <- decode.field(3, decode.optional(decode.string))
  use subscribed <- decode.field(4, decode.bool)
  use exclusion_reason <- decode.field(5, decode.optional(decode.string))
  use format <- decode.field(6, decode.optional(decode.string))
  use last_polled_at <- decode.field(
    7,
    decode.optional(alert.timestamptz_decoder()),
  )
  use last_success_at <- decode.field(
    8,
    decode.optional(alert.timestamptz_decoder()),
  )
  use last_http_status <- decode.field(9, decode.optional(decode.int))
  use last_error <- decode.field(10, decode.optional(decode.string))
  use consecutive_failures <- decode.field(11, decode.int)
  use item_count <- decode.field(12, decode.optional(decode.int))
  use newest_item_at <- decode.field(
    13,
    decode.optional(alert.timestamptz_decoder()),
  )
  use authority_source <- decode.field(14, decode.string)
  use authority_name <- decode.field(15, decode.string)
  use authority_country_name <- decode.field(16, decode.string)
  use authority_country_iso3 <- decode.field(17, decode.string)
  use active_alerts <- decode.field(18, decode.optional(decode.int))
  use failed_items <- decode.field(19, decode.optional(decode.int))
  decode.success(FeedRow(
    url:,
    authority_oid:,
    authority_oids:,
    language:,
    subscribed:,
    exclusion_reason:,
    format:,
    last_polled_at:,
    last_success_at:,
    last_http_status:,
    last_error:,
    consecutive_failures:,
    item_count:,
    newest_item_at:,
    authority_source:,
    authority_name:,
    authority_country_name:,
    authority_country_iso3:,
    active_alerts:,
    failed_items:,
  ))
}

const feed_view_sql = "
  SELECT
    f.url,
    f.authority_oid,
    f.authority_oids,
    f.language,
    f.subscribed,
    f.exclusion_reason,
    f.format,
    f.last_polled_at,
    f.last_success_at,
    f.last_http_status,
    f.last_error,
    f.consecutive_failures,
    f.item_count,
    f.newest_item_at,
    a.source,
    a.name,
    a.country_name,
    a.country_iso3,
    alert_counts.active_alerts,
    failed_item_counts.failed_items
  FROM sea.cap_feed f
  JOIN sea.cap_authority a ON a.oid = f.authority_oid
  LEFT JOIN (
    SELECT m.feed_url, count(*) AS active_alerts
    FROM sea.alert a
    JOIN sea.cap_message m ON m.sender = a.sender AND m.identifier = a.identifier
    WHERE a.ended_at IS NULL AND a.active_until > $1
    GROUP BY m.feed_url
  ) alert_counts ON alert_counts.feed_url = f.url
  LEFT JOIN (
    SELECT feed_url, count(*) AS failed_items
    FROM sea.cap_item
    WHERE state = 'failed'
    GROUP BY feed_url
  ) failed_item_counts ON failed_item_counts.feed_url = f.url
  ORDER BY a.country_name ASC, a.name ASC, f.url ASC"

pub fn view(
  now: Timestamp,
  conn: pog.Connection,
) -> Result(CapFeedsView, String) {
  use reg_res <- result.try(
    pog.query("SELECT max(last_seen_at) FROM sea.cap_authority")
    |> pog.returning(decode.at(
      [0],
      decode.optional(alert.timestamptz_decoder()),
    ))
    |> pog.execute(conn)
    |> result.map_error(err),
  )
  let registry_fetched_at = case list.first(reg_res.rows) {
    Ok(opt) -> opt
    Error(Nil) -> option.None
  }

  use feeds_res <- result.try(
    pog.query(feed_view_sql)
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(feed_row_decoder())
    |> pog.execute(conn)
    |> result.map_error(err),
  )

  let feeds =
    list.map(feeds_res.rows, fn(row) {
      let health =
        raa.classify_feed_health(
          row.subscribed,
          row.last_polled_at,
          row.consecutive_failures,
          row.item_count,
          row.newest_item_at,
          now,
        )
      CapFeedView(
        url: row.url,
        health: raa.feed_health_to_string(health),
        authority: CapAuthorityView(
          oid: row.authority_oid,
          source: row.authority_source,
          name: row.authority_name,
          country_name: row.authority_country_name,
          country_iso3: row.authority_country_iso3,
        ),
        authority_oids: row.authority_oids,
        language: row.language,
        subscribed: row.subscribed,
        exclusion_reason: row.exclusion_reason,
        format: row.format,
        last_polled_at: row.last_polled_at,
        last_success_at: row.last_success_at,
        last_http_status: row.last_http_status,
        last_error: row.last_error,
        consecutive_failures: row.consecutive_failures,
        item_count: row.item_count,
        newest_item_at: row.newest_item_at,
        active_alerts: option.unwrap(row.active_alerts, 0),
        failed_items: option.unwrap(row.failed_items, 0),
      )
    })

  let counts =
    list.fold(feeds, CapHealthCounts(0, 0, 0, 0, 0, 0, 0), fn(acc, feed) {
      case feed.health {
        "ok" -> CapHealthCounts(..acc, ok: acc.ok + 1)
        "empty" -> CapHealthCounts(..acc, empty: acc.empty + 1)
        "stale" -> CapHealthCounts(..acc, stale: acc.stale + 1)
        "degraded" -> CapHealthCounts(..acc, degraded: acc.degraded + 1)
        "failing" -> CapHealthCounts(..acc, failing: acc.failing + 1)
        "pending" -> CapHealthCounts(..acc, pending: acc.pending + 1)
        "excluded" -> CapHealthCounts(..acc, excluded: acc.excluded + 1)
        _ -> acc
      }
    })

  Ok(CapFeedsView(
    generated_at: now,
    registry_fetched_at: registry_fetched_at,
    counts:,
    feeds:,
  ))
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}

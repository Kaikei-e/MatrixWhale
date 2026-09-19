import domain/alert
import domain/cap
import domain/raa.{type ParsedAuthority, type SelectedFeed}
import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/cap as models_cap
import pog

pub type RegistryAck {
  RegistryAck(received: Int, written: Int, deduped: Int, dropped: Int)
}

type ExistingAuthority {
  ExistingAuthority(
    oid: String,
    name: String,
    country_name: String,
    country_iso3: String,
    abbrev: Option(String),
    register_url: Option(String),
    categories: List(String),
    raa_pub_date: Option(Timestamp),
    removed_at: Option(Timestamp),
  )
}

fn existing_authority_decoder() -> decode.Decoder(ExistingAuthority) {
  use oid <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use country_name <- decode.field(2, decode.string)
  use country_iso3 <- decode.field(3, decode.string)
  use abbrev <- decode.field(4, decode.optional(decode.string))
  use register_url <- decode.field(5, decode.optional(decode.string))
  use categories <- decode.field(6, decode.list(decode.string))
  use raa_pub_date <- decode.field(
    7,
    decode.optional(alert.timestamptz_decoder()),
  )
  use removed_at <- decode.field(
    8,
    decode.optional(alert.timestamptz_decoder()),
  )
  decode.success(ExistingAuthority(
    oid:,
    name:,
    country_name:,
    country_iso3:,
    abbrev:,
    register_url:,
    categories:,
    raa_pub_date:,
    removed_at:,
  ))
}

pub fn write_registry(
  items: List(models_cap.RegistryItem),
  received: Int,
  decode_dropped: Int,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(RegistryAck, String) {
  let #(parsed_authorities, parse_dropped, _) =
    list.fold(items, #([], 0, set.new()), fn(acc, item) {
      let #(parsed, dropped, seen_oids) = acc
      case raa.parse_authority(item) {
        Ok(auth) ->
          case set.contains(seen_oids, auth.oid) {
            True -> #(parsed, dropped + 1, seen_oids)
            False -> #(
              [auth, ..parsed],
              dropped,
              set.insert(seen_oids, auth.oid),
            )
          }
        Error(Nil) -> #(parsed, dropped + 1, seen_oids)
      }
    })
  let parsed_authorities = list.reverse(parsed_authorities)
  let total_dropped = decode_dropped + parse_dropped

  case parsed_authorities {
    [] -> Error("zero authorities parsed from registry")
    _ -> {
      pog.transaction(conn, fn(tx) {
        write_registry_tx(parsed_authorities, received, total_dropped, now, tx)
      })
      |> result.map_error(fn(x) {
        case x {
          pog.TransactionQueryError(e) -> err(e)
          pog.TransactionRolledBack(e) -> e
        }
      })
    }
  }
}

fn write_registry_tx(
  authorities: List(ParsedAuthority),
  received: Int,
  dropped: Int,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(RegistryAck, String) {
  use existing_authorities <- result.try(load_existing_authorities(tx))
  let db_authority_oids = list.map(existing_authorities, fn(a) { a.oid })
  let existing_map =
    dict.from_list(list.map(existing_authorities, fn(a) { #(a.oid, a) }))

  use db_feed_urls <- result.try(load_existing_feed_urls(tx))

  // Select feeds
  let selection = raa.select_feeds(authorities, db_feed_urls, db_authority_oids)

  // Decision in Gleam: filter to authorities not already removed
  let newly_removed_oids =
    list.filter(selection.removed_authority_oids, fn(oid) {
      case dict.get(existing_map, oid) {
        Ok(a) -> option.is_none(a.removed_at)
        Error(Nil) -> False
      }
    })

  let known_active =
    list.filter(existing_authorities, fn(a) { option.is_none(a.removed_at) })
  let known_count = list.length(known_active)

  case known_count > 0 && list.length(newly_removed_oids) * 2 > known_count {
    True -> Error("registry would remove more than half of known authorities")
    False -> {
      let #(new_auths, changed_auths, unchanged_auths) =
        classify_authorities(authorities, existing_map)

      // 1. Upsert sea.source for all parsed authorities
      use _ <- result.try(upsert_sources(authorities, tx))

      // 2. Insert new authorities
      use _ <- result.try(insert_authorities(new_auths, now, tx))

      // 3. Update changed authorities
      use _ <- result.try(update_authorities(changed_auths, now, tx))

      // 4. Touch unchanged authorities
      use _ <- result.try(touch_authorities(unchanged_auths, now, tx))

      // 6. Upsert feeds
      use _ <- result.try(upsert_feeds(selection.feeds, now, tx))

      // 7. Mark removed feeds (do not bump last_seen_at)
      use _ <- result.try(mark_removed_feeds(selection.removed_feed_urls, tx))

      // 8. Mark removed authorities (decision in Gleam)
      use _ <- result.try(mark_removed_authorities(newly_removed_oids, now, tx))

      let written = list.length(new_auths) + list.length(changed_auths)
      let deduped = list.length(unchanged_auths)

      Ok(RegistryAck(received:, written:, deduped:, dropped:))
    }
  }
}

fn load_existing_authorities(
  conn: pog.Connection,
) -> Result(List(ExistingAuthority), String) {
  pog.query(
    "SELECT oid, name, country_name, country_iso3, abbrev, register_url, categories, raa_pub_date, removed_at FROM sea.cap_authority",
  )
  |> pog.returning(existing_authority_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn load_existing_feed_urls(
  conn: pog.Connection,
) -> Result(List(String), String) {
  pog.query("SELECT url FROM sea.cap_feed")
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn classify_authorities(
  authorities: List(ParsedAuthority),
  existing_map: dict.Dict(String, ExistingAuthority),
) -> #(List(ParsedAuthority), List(ParsedAuthority), List(ParsedAuthority)) {
  list.fold(authorities, #([], [], []), fn(acc, auth) {
    let #(new_acc, changed_acc, unchanged_acc) = acc
    case dict.get(existing_map, auth.oid) {
      Error(Nil) -> #([auth, ..new_acc], changed_acc, unchanged_acc)
      Ok(existing) -> {
        let auth_pub_date =
          option.then(auth.pub_date, fn(s) {
            option.from_result(cap.parse_published_time(s))
          })
        let is_changed =
          existing.name != auth.name
          || existing.country_name != auth.country_name
          || existing.country_iso3 != auth.country_iso3
          || existing.abbrev != auth.abbrev
          || existing.register_url != auth.register_url
          || existing.categories != auth.categories
          || existing.raa_pub_date != auth_pub_date
          || option.is_some(existing.removed_at)

        case is_changed {
          True -> #(new_acc, [auth, ..changed_acc], unchanged_acc)
          False -> #(new_acc, changed_acc, [auth, ..unchanged_acc])
        }
      }
    }
  })
}

const upsert_source_sql = "
  INSERT INTO sea.source
    (id, name, homepage, license, attribution_text, redistributable, priority)
  VALUES
    ($1, $2, $3, $4, $5, $6, $7)
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    homepage = EXCLUDED.homepage,
    license = EXCLUDED.license,
    attribution_text = EXCLUDED.attribution_text,
    redistributable = EXCLUDED.redistributable,
    priority = EXCLUDED.priority"

fn upsert_sources(
  authorities: List(ParsedAuthority),
  conn: pog.Connection,
) -> Result(Nil, String) {
  list.try_each(authorities, fn(auth) {
    pog.query(upsert_source_sql)
    |> pog.parameter(pog.text(auth.source.id))
    |> pog.parameter(pog.text(auth.source.name))
    |> pog.parameter(pog.nullable(pog.text, auth.source.homepage))
    |> pog.parameter(pog.text(auth.source.license))
    |> pog.parameter(pog.text(auth.source.attribution_text))
    |> pog.parameter(pog.bool(auth.source.redistributable))
    |> pog.parameter(pog.int(auth.source.priority))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err)
  })
}

const insert_authority_sql = "
  INSERT INTO sea.cap_authority
    (oid, source, name, country_name, country_iso3, abbrev, register_url, categories, raa_pub_date, first_seen_at, last_seen_at, removed_at)
  VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10, NULL)"

fn insert_authorities(
  authorities: List(ParsedAuthority),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  list.try_each(authorities, fn(auth) {
    let raa_pub_date =
      option.then(auth.pub_date, fn(s) {
        option.from_result(cap.parse_published_time(s))
      })
    pog.query(insert_authority_sql)
    |> pog.parameter(pog.text(auth.oid))
    |> pog.parameter(pog.text(auth.source.id))
    |> pog.parameter(pog.text(auth.name))
    |> pog.parameter(pog.text(auth.country_name))
    |> pog.parameter(pog.text(auth.country_iso3))
    |> pog.parameter(pog.nullable(pog.text, auth.abbrev))
    |> pog.parameter(pog.nullable(pog.text, auth.register_url))
    |> pog.parameter(pog.array(pog.text, auth.categories))
    |> pog.parameter(pog.nullable(pog.timestamp, raa_pub_date))
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err)
  })
}

const update_authority_sql = "
  UPDATE sea.cap_authority SET
    source = $2,
    name = $3,
    country_name = $4,
    country_iso3 = $5,
    abbrev = $6,
    register_url = $7,
    categories = $8,
    raa_pub_date = $9,
    last_seen_at = $10,
    removed_at = NULL
  WHERE oid = $1"

fn update_authorities(
  authorities: List(ParsedAuthority),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  list.try_each(authorities, fn(auth) {
    let raa_pub_date =
      option.then(auth.pub_date, fn(s) {
        option.from_result(cap.parse_published_time(s))
      })
    pog.query(update_authority_sql)
    |> pog.parameter(pog.text(auth.oid))
    |> pog.parameter(pog.text(auth.source.id))
    |> pog.parameter(pog.text(auth.name))
    |> pog.parameter(pog.text(auth.country_name))
    |> pog.parameter(pog.text(auth.country_iso3))
    |> pog.parameter(pog.nullable(pog.text, auth.abbrev))
    |> pog.parameter(pog.nullable(pog.text, auth.register_url))
    |> pog.parameter(pog.array(pog.text, auth.categories))
    |> pog.parameter(pog.nullable(pog.timestamp, raa_pub_date))
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err)
  })
}

fn touch_authorities(
  authorities: List(ParsedAuthority),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  case authorities {
    [] -> Ok(Nil)
    _ -> {
      let oids = list.map(authorities, fn(a) { a.oid })
      pog.query(
        "UPDATE sea.cap_authority SET last_seen_at = $2 WHERE oid = ANY($1)",
      )
      |> pog.parameter(pog.array(pog.text, oids))
      |> pog.parameter(pog.timestamp(now))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)
      |> result.map(fn(_) { Nil })
      |> result.map_error(err)
    }
  }
}

const upsert_feed_sql = "
  INSERT INTO sea.cap_feed
    (url, authority_oid, authority_oids, language, subscribed, exclusion_reason,
     format, last_polled_at, last_success_at, last_http_status, last_error,
     consecutive_failures, item_count, newest_item_at, first_seen_at, last_seen_at)
  VALUES
    ($1, $2, $3, $4, $5, $6,
     NULL, NULL, NULL, NULL, NULL,
     0, NULL, NULL, $7, $7)
  ON CONFLICT (url) DO UPDATE SET
    authority_oid = EXCLUDED.authority_oid,
    authority_oids = EXCLUDED.authority_oids,
    language = EXCLUDED.language,
    subscribed = EXCLUDED.subscribed,
    exclusion_reason = EXCLUDED.exclusion_reason,
    last_seen_at = EXCLUDED.last_seen_at"

fn upsert_feeds(
  feeds: List(SelectedFeed),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  list.try_each(feeds, fn(feed) {
    pog.query(upsert_feed_sql)
    |> pog.parameter(pog.text(feed.url))
    |> pog.parameter(pog.text(feed.authority_oid))
    |> pog.parameter(pog.array(pog.text, feed.authority_oids))
    |> pog.parameter(pog.nullable(pog.text, feed.language))
    |> pog.parameter(pog.bool(feed.subscribed))
    |> pog.parameter(pog.nullable(pog.text, feed.exclusion_reason))
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err)
  })
}

fn mark_removed_feeds(
  removed_urls: List(String),
  conn: pog.Connection,
) -> Result(Nil, String) {
  case removed_urls {
    [] -> Ok(Nil)
    _ ->
      pog.query(
        "UPDATE sea.cap_feed SET subscribed = false, exclusion_reason = 'removed' WHERE url = ANY($1)",
      )
      |> pog.parameter(pog.array(pog.text, removed_urls))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)
      |> result.map(fn(_) { Nil })
      |> result.map_error(err)
  }
}

fn mark_removed_authorities(
  removed_oids: List(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  case removed_oids {
    [] -> Ok(Nil)
    _ ->
      pog.query(
        "UPDATE sea.cap_authority SET removed_at = $2 WHERE oid = ANY($1)",
      )
      |> pog.parameter(pog.array(pog.text, removed_oids))
      |> pog.parameter(pog.timestamp(now))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)
      |> result.map(fn(_) { Nil })
      |> result.map_error(err)
  }
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}

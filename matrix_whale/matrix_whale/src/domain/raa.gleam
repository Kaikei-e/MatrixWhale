import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/cap as models_cap

pub type AuthoritySource {
  AuthoritySource(
    id: String,
    name: String,
    homepage: Option(String),
    license: String,
    attribution_text: String,
    redistributable: Bool,
    priority: Int,
  )
}

pub type ParsedAuthority {
  ParsedAuthority(
    oid: String,
    source: AuthoritySource,
    name: String,
    country_name: String,
    country_iso3: String,
    abbrev: Option(String),
    register_url: Option(String),
    categories: List(String),
    pub_date: Option(String),
    feeds: List(models_cap.RegistryFeed),
  )
}

pub type SelectedFeed {
  SelectedFeed(
    url: String,
    authority_oid: String,
    authority_oids: List(String),
    language: Option(String),
    subscribed: Bool,
    exclusion_reason: Option(String),
  )
}

pub type FeedSelectionResult {
  FeedSelectionResult(
    feeds: List(SelectedFeed),
    removed_feed_urls: List(String),
    removed_authority_oids: List(String),
  )
}

pub type FeedHealth {
  HealthOk
  HealthEmpty
  HealthStale
  HealthDegraded
  HealthFailing
  HealthPending
  HealthExcluded
}

pub fn feed_health_to_string(health: FeedHealth) -> String {
  case health {
    HealthOk -> "ok"
    HealthEmpty -> "empty"
    HealthStale -> "stale"
    HealthDegraded -> "degraded"
    HealthFailing -> "failing"
    HealthPending -> "pending"
    HealthExcluded -> "excluded"
  }
}

pub fn oid_from_guid(guid: String) -> Result(String, Nil) {
  let trimmed = string.trim(guid)
  let stripped = case string.starts_with(trimmed, "urn:oid:") {
    True -> string.drop_start(trimmed, 8)
    False -> trimmed
  }
  let oid = string.trim(stripped)
  case oid != "" && !string.contains(oid, ":") {
    True -> Ok(oid)
    False -> Error(Nil)
  }
}

pub fn split_title(title: String) -> #(String, String) {
  let trimmed = string.trim(title)
  case string.split_once(trimmed, ": ") {
    Ok(#(country, name)) -> #(string.trim(country), string.trim(name))
    Error(Nil) -> #(trimmed, trimmed)
  }
}

pub fn parse_categories(description: String) -> List(String) {
  let lower = string.lowercase(description)
  case string.split_once(lower, "categories:") {
    Error(Nil) -> []
    Ok(#(before, _)) -> {
      let index = string.length(before) + string.length("categories:")
      let after = string.drop_start(description, index)
      let cleaned = string.trim(after)
      let without_dot = case string.ends_with(cleaned, ".") {
        True -> string.drop_end(cleaned, 1)
        False -> cleaned
      }
      without_dot
      |> string.split("\n")
      |> list.flat_map(string.split(_, " "))
      |> list.flat_map(string.split(_, "\t"))
      |> list.map(string.trim)
      |> list.filter(fn(word) { word != "" })
    }
  }
}

pub fn make_authority_source(
  oid: String,
  name: String,
  country_name: String,
  homepage: Option(String),
) -> AuthoritySource {
  AuthoritySource(
    id: "cap-" <> oid,
    name:,
    homepage:,
    license: "Unknown (terms not published in the WMO Register of Alerting Authorities)",
    attribution_text: name
      <> " ("
      <> country_name
      <> "), via the WMO Register of Alerting Authorities",
    redistributable: False,
    priority: 70,
  )
}

pub fn parse_authority(
  item: models_cap.RegistryItem,
) -> Result(ParsedAuthority, Nil) {
  case oid_from_guid(item.guid) {
    Error(Nil) -> Error(Nil)
    Ok(oid) -> {
      let title_str = option.unwrap(item.title, "")
      let #(country_name, raw_name) = split_title(title_str)
      let name = case raw_name {
        "" ->
          case country_name {
            "" -> "Unknown"
            _ -> country_name
          }
        _ -> raw_name
      }
      let country = case country_name {
        "" -> name
        _ -> country_name
      }
      let source = make_authority_source(oid, name, country, item.link)
      let categories =
        item.description
        |> option.map(parse_categories)
        |> option.unwrap([])
      let country_iso3 = option.unwrap(item.country_iso3, "")
      Ok(ParsedAuthority(
        oid:,
        source:,
        name:,
        country_name: country,
        country_iso3:,
        abbrev: item.abbrev,
        register_url: item.link,
        categories:,
        pub_date: item.pub_date,
        feeds: item.feeds,
      ))
    }
  }
}

pub fn primary_language_subtag(lang: Option(String)) -> String {
  let effective = case lang {
    Some(s) -> {
      let trimmed = string.trim(s)
      case trimmed {
        "" -> "en-US"
        _ -> trimmed
      }
    }
    None -> "en-US"
  }
  case string.split_once(effective, "-") {
    Ok(#(subtag, _)) -> string.lowercase(string.trim(subtag))
    Error(Nil) ->
      case string.split_once(effective, "_") {
        Ok(#(subtag, _)) -> string.lowercase(string.trim(subtag))
        Error(Nil) -> string.lowercase(string.trim(effective))
      }
  }
}

pub fn extract_host(url: String) -> Option(String) {
  let trimmed = string.trim(url)
  let without_scheme = case string.split_once(trimmed, "://") {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> trimmed
  }
  let host_and_port = case string.split_once(without_scheme, "/") {
    Ok(#(h, _)) -> h
    Error(Nil) ->
      case string.split_once(without_scheme, "?") {
        Ok(#(h, _)) -> h
        Error(Nil) -> without_scheme
      }
  }
  let host_only = case string.split_once(host_and_port, ":") {
    Ok(#(h, _)) -> h
    Error(Nil) -> host_and_port
  }
  let result = string.lowercase(string.trim(host_only))
  case result {
    "" -> None
    _ -> Some(result)
  }
}

pub fn is_nws_url(url: String) -> Bool {
  case extract_host(url) {
    Some(host) -> host == "alerts.weather.gov" || host == "api.weather.gov"
    None -> False
  }
}

pub fn select_feeds(
  authorities: List(ParsedAuthority),
  db_feed_urls: List(String),
  db_authority_oids: List(String),
) -> FeedSelectionResult {
  // Collect all distinct trimmed URLs in document order of first appearance
  let distinct_urls =
    list.fold(authorities, [], fn(acc, auth) {
      list.fold(auth.feeds, acc, fn(inner_acc, feed) {
        let u = string.trim(feed.url)
        case u != "" && !list.contains(inner_acc, u) {
          True -> list.append(inner_acc, [u])
          False -> inner_acc
        }
      })
    })

  let selected_feeds =
    list.map(distinct_urls, fn(url) {
      let listers =
        list.filter(authorities, fn(auth) {
          list.any(auth.feeds, fn(feed) { string.trim(feed.url) == url })
        })

      let assert [owner, ..] = listers
      let authority_oids = list.map(listers, fn(a) { a.oid })

      let owner_feed =
        list.find(owner.feeds, fn(feed) { string.trim(feed.url) == url })
      let language = case owner_feed {
        Ok(f) -> f.language
        Error(Nil) -> None
      }

      // Check exclusion votes from each lister
      let votes =
        list.map(listers, fn(auth) {
          case is_nws_url(url) {
            True -> Some("nws")
            False -> {
              let has_en =
                list.any(auth.feeds, fn(f) {
                  primary_language_subtag(f.language) == "en"
                })
              let has_non_en =
                list.any(auth.feeds, fn(f) {
                  primary_language_subtag(f.language) != "en"
                })
              case has_en && has_non_en {
                True -> {
                  let feed_match =
                    list.find(auth.feeds, fn(f) { string.trim(f.url) == url })
                  let feed_lang = case feed_match {
                    Ok(f) -> f.language
                    Error(Nil) -> None
                  }
                  case primary_language_subtag(feed_lang) != "en" {
                    True -> Some("language")
                    False -> None
                  }
                }
                False -> None
              }
            }
          }
        })

      // A URL is excluded only if EVERY authority listing it excludes it
      let every_excludes = list.all(votes, fn(v) { option.is_some(v) })

      let #(subscribed, exclusion_reason) = case every_excludes {
        True -> {
          let reason = case list.any(votes, fn(v) { v == Some("nws") }) {
            True -> Some("nws")
            False ->
              case list.all(votes, fn(v) { v == Some("language") }) {
                True -> Some("language")
                False ->
                  case list.first(votes) {
                    Ok(Some(r)) -> Some(r)
                    _ -> Some("excluded")
                  }
              }
          }
          #(False, reason)
        }
        False -> #(True, None)
      }

      SelectedFeed(
        url:,
        authority_oid: owner.oid,
        authority_oids:,
        language:,
        subscribed:,
        exclusion_reason:,
      )
    })

  let raa_urls = distinct_urls
  let removed_feed_urls =
    list.filter(db_feed_urls, fn(url) {
      let trimmed = string.trim(url)
      trimmed != "" && !list.contains(raa_urls, trimmed)
    })

  let raa_oids = list.map(authorities, fn(a) { a.oid })
  let removed_authority_oids =
    list.filter(db_authority_oids, fn(oid) {
      let trimmed = string.trim(oid)
      trimmed != "" && !list.contains(raa_oids, trimmed)
    })

  FeedSelectionResult(
    feeds: selected_feeds,
    removed_feed_urls:,
    removed_authority_oids:,
  )
}

pub fn poll_interval_seconds(consecutive_failures: Int) -> Int {
  case consecutive_failures < 3 {
    True -> 300
    False ->
      case consecutive_failures < 10 {
        True -> 3600
        False -> 21_600
      }
  }
}

pub fn classify_feed_health(
  subscribed: Bool,
  last_polled_at: Option(Timestamp),
  consecutive_failures: Int,
  item_count: Option(Int),
  newest_item_at: Option(Timestamp),
  now: Timestamp,
) -> FeedHealth {
  case subscribed {
    False -> HealthExcluded
    True ->
      case last_polled_at {
        None -> HealthPending
        Some(_) ->
          case consecutive_failures >= 3 {
            True -> HealthFailing
            False ->
              case consecutive_failures > 0 {
                True -> HealthDegraded
                False -> {
                  let is_stale = case newest_item_at {
                    Some(item_time) -> {
                      let #(now_sec, _) =
                        timestamp.to_unix_seconds_and_nanoseconds(now)
                      let #(item_sec, _) =
                        timestamp.to_unix_seconds_and_nanoseconds(item_time)
                      now_sec - item_sec > 2_592_000
                    }
                    None -> False
                  }
                  case is_stale {
                    True -> HealthStale
                    False ->
                      case item_count {
                        Some(0) -> HealthEmpty
                        _ -> HealthOk
                      }
                  }
                }
              }
          }
      }
  }
}

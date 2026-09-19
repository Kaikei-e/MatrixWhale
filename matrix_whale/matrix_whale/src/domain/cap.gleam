import domain/cap_geometry
import domain/raa
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import intake/record
import message/reciever/models/cap as models_cap

pub type ItemState {
  Pending
  Fetched
  Skipped
  Failed
}

pub fn item_state_to_string(state: ItemState) -> String {
  case state {
    Pending -> "pending"
    Fetched -> "fetched"
    Skipped -> "skipped"
    Failed -> "failed"
  }
}

pub type NormalizedAlert {
  NormalizedAlert(
    source: String,
    source_id: String,
    sender: Option(String),
    sender_name: Option(String),
    identifier: Option(String),
    message_type: String,
    event: String,
    category: List(String),
    severity: String,
    urgency: String,
    certainty: String,
    headline: Option(String),
    description: Option(String),
    instruction: Option(String),
    web: Option(String),
    contact: Option(String),
    language: Option(String),
    area_desc: String,
    geocodes: List(models_cap.ValuePair),
    countries: List(String),
    geom: Option(String),
    reference_keys: List(String),
    sent: Option(Timestamp),
    effective: Option(Timestamp),
    onset: Option(Timestamp),
    expires: Option(Timestamp),
    ends: Option(Timestamp),
    active_until: Timestamp,
    ended_at: Option(Timestamp),
    end_reason: Option(String),
    superseded_by: Option(String),
  )
}

pub type StoredMessageRef {
  StoredMessageRef(
    key: String,
    msg_type: String,
    status: String,
    scope: String,
    public_id: String,
    normalized: Bool,
  )
}

pub type ActiveAlertRef {
  ActiveAlertRef(source: String, source_id: String)
}

pub type EndAlertAction {
  EndAlertAction(
    source: String,
    source_id: String,
    ended_at: Timestamp,
    end_reason: String,
    superseded_by: Option(String),
  )
}

pub type InsertionEndingState {
  NotEnded
  InsertedEnded(
    ended_at: Timestamp,
    end_reason: String,
    superseded_by: Option(String),
  )
}

pub type ResolutionResult {
  ResolutionResult(
    incoming_ending: InsertionEndingState,
    rows_to_end: List(EndAlertAction),
  )
}

pub type NormalizeError {
  NotEligible
  InvalidSent
  NoInfo
}

pub fn parse_rfc3339(s: String) -> Result(Timestamp, Nil) {
  let trimmed = string.trim(s)
  case trimmed == "" {
    True -> Error(Nil)
    False -> {
      case timestamp.parse_rfc3339(trimmed) {
        Ok(t) -> Ok(t)
        Error(Nil) -> {
          let with_t = string.replace(trimmed, " ", "T")
          case timestamp.parse_rfc3339(with_t) {
            Ok(t) -> Ok(t)
            Error(Nil) ->
              case timestamp.parse_rfc3339(with_t <> "Z") {
                Ok(t) -> Ok(t)
                Error(Nil) -> parse_rfc1123(trimmed)
              }
          }
        }
      }
    }
  }
}

pub fn parse_published_time(s: String) -> Result(Timestamp, Nil) {
  let trimmed = string.trim(s)
  case parse_rfc3339(trimmed) {
    Ok(t) -> Ok(t)
    Error(Nil) -> parse_rfc1123(trimmed)
  }
}

pub fn parse_rfc1123(s: String) -> Result(Timestamp, Nil) {
  case timestamp.parse_http_date(s) {
    Ok(t) -> Ok(t)
    Error(Nil) -> {
      let trimmed = string.trim(s)
      let without_weekday = case string.split_once(trimmed, ",") {
        Ok(#(_, rest)) -> string.trim(rest)
        Error(Nil) -> trimmed
      }
      let tokens =
        without_weekday
        |> string.split(" ")
        |> list.map(string.trim)
        |> list.filter(fn(t) { t != "" })
      let parsed_parts = case tokens {
        [day_str, month_str, year_str, time_str, offset_str] ->
          Ok(#(day_str, month_str, year_str, time_str, offset_str))
        [day_str, month_str, year_str, time_and_offset] ->
          case split_time_and_offset(time_and_offset) {
            Ok(#(time_str, offset_str)) ->
              Ok(#(day_str, month_str, year_str, time_str, offset_str))
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
      case parsed_parts {
        Ok(#(day_str, month_str, year_str, time_str, offset_str)) -> {
          case
            int.parse(day_str),
            parse_month_name(month_str),
            int.parse(year_str),
            parse_time_parts(time_str),
            parse_offset_seconds(offset_str)
          {
            Ok(day), Ok(month), Ok(raw_year), Ok(#(h, m, sec)), Ok(offset_sec)
            -> {
              let year = case raw_year >= 0 && raw_year < 100 {
                True -> 2000 + raw_year
                False -> raw_year
              }
              let date = calendar.Date(year:, month:, day:)
              case calendar.is_valid_date(date) {
                True -> {
                  let time =
                    calendar.TimeOfDay(
                      hours: h,
                      minutes: m,
                      seconds: sec,
                      nanoseconds: 0,
                    )
                  let offset = duration.seconds(offset_sec)
                  Ok(timestamp.from_calendar(date:, time:, offset:))
                }
                False -> Error(Nil)
              }
            }
            _, _, _, _, _ -> Error(Nil)
          }
        }
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn split_time_and_offset(s: String) -> Result(#(String, String), Nil) {
  // Split on "+" first (e.g. "+0530"), then on "-" only after the time part.
  // We locate a sign character that appears after at least "hh:mm" (5 chars).
  case string.split_once(s, "+") {
    Ok(#(t, off)) -> Ok(#(t, "+" <> off))
    Error(Nil) -> {
      let upper = string.uppercase(s)
      case string.ends_with(upper, "GMT") {
        True -> Ok(#(string.slice(s, 0, string.length(s) - 3), "GMT"))
        False ->
          case string.ends_with(upper, "UTC") {
            True -> Ok(#(string.slice(s, 0, string.length(s) - 3), "UTC"))
            False ->
              case string.ends_with(upper, "Z") {
                True -> Ok(#(string.slice(s, 0, string.length(s) - 1), "Z"))
                False ->
                  // "-" sign: only valid as offset sign when the time part
                  // precedes it (at least 5 chars before the last "-").
                  case split_on_trailing_minus(s) {
                    Ok(#(t, off)) -> Ok(#(t, "-" <> off))
                    Error(Nil) ->
                      case parse_time_parts(s) {
                        Ok(_) -> Ok(#(s, "GMT"))
                        Error(Nil) -> Error(Nil)
                      }
                  }
              }
          }
      }
    }
  }
}

// Find the last "-" in s that appears after at least 5 characters (hh:mm).
fn split_on_trailing_minus(s: String) -> Result(#(String, String), Nil) {
  find_last_minus(s, string.length(s) - 1)
}

fn find_last_minus(s: String, idx: Int) -> Result(#(String, String), Nil) {
  case idx < 5 {
    True -> Error(Nil)
    False ->
      case string.slice(s, idx, 1) == "-" {
        True -> Ok(#(string.slice(s, 0, idx), string.drop_start(s, idx + 1)))
        False -> find_last_minus(s, idx - 1)
      }
  }
}

fn parse_time_parts(s: String) -> Result(#(Int, Int, Int), Nil) {
  case string.split(s, ":") {
    [h_str, m_str, s_str] ->
      case int.parse(h_str), int.parse(m_str), int.parse(s_str) {
        Ok(h), Ok(m), Ok(sec) ->
          case h >= 0 && h <= 23 && m >= 0 && m <= 59 && sec >= 0 && sec <= 60 {
            True -> Ok(#(h, m, sec))
            False -> Error(Nil)
          }
        _, _, _ -> Error(Nil)
      }
    [h_str, m_str] ->
      case int.parse(h_str), int.parse(m_str) {
        Ok(h), Ok(m) ->
          case h >= 0 && h <= 23 && m >= 0 && m <= 59 {
            True -> Ok(#(h, m, 0))
            False -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn parse_offset_seconds(s: String) -> Result(Int, Nil) {
  let cleaned = string.trim(s)
  case string.uppercase(cleaned) {
    "GMT" | "UTC" | "Z" -> Ok(0)
    "+" <> digits | "-" <> digits -> {
      let sign = case string.starts_with(cleaned, "-") {
        True -> -1
        False -> 1
      }
      let num_str = string.replace(digits, ":", "")
      case string.length(num_str) == 4, int.parse(num_str) {
        True, Ok(num) -> {
          let hours = num / 100
          let minutes = num % 100
          Ok(sign * { hours * 3600 + minutes * 60 })
        }
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn parse_month_name(m: String) -> Result(calendar.Month, Nil) {
  case string.lowercase(m) {
    "jan" | "january" -> Ok(calendar.January)
    "feb" | "february" -> Ok(calendar.February)
    "mar" | "march" -> Ok(calendar.March)
    "apr" | "april" -> Ok(calendar.April)
    "may" -> Ok(calendar.May)
    "jun" | "june" -> Ok(calendar.June)
    "jul" | "july" -> Ok(calendar.July)
    "aug" | "august" -> Ok(calendar.August)
    "sep" | "september" -> Ok(calendar.September)
    "oct" | "october" -> Ok(calendar.October)
    "nov" | "november" -> Ok(calendar.November)
    "dec" | "december" -> Ok(calendar.December)
    _ -> Error(Nil)
  }
}

pub fn decide_new_item_state(
  published: Option(String),
  now: Timestamp,
) -> ItemState {
  case published {
    Some(pub_str) ->
      case parse_published_time(pub_str) {
        Ok(pub_time) -> {
          let #(now_sec, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
          let #(pub_sec, _) =
            timestamp.to_unix_seconds_and_nanoseconds(pub_time)
          let diff_seconds = now_sec - pub_sec
          case diff_seconds > 604_800 {
            True -> Skipped
            False -> Pending
          }
        }
        Error(Nil) -> Pending
      }
    None -> Pending
  }
}

pub fn decide_fetch_outcome(
  http_status: Int,
  cap_parsed: Bool,
  current_attempts: Int,
) -> #(ItemState, Int) {
  case cap_parsed {
    True -> #(Fetched, current_attempts)
    False ->
      case http_status == 429 || http_status >= 500 || http_status == 0 {
        True -> #(Failed, current_attempts + 1)
        False -> #(Failed, 3)
      }
  }
}

pub fn decide_write_failure(current_attempts: Int) -> #(ItemState, Int) {
  #(Failed, current_attempts + 1)
}

pub const max_retry_attempts = 3

pub const retry_interval_seconds = 900

pub fn should_normalize(
  status: String,
  scope: String,
  msg_type: String,
) -> Bool {
  let stat = string.lowercase(string.trim(status))
  let scp = string.lowercase(string.trim(scope))
  let msg = string.lowercase(string.trim(msg_type))
  stat == "actual" && scp == "public" && { msg == "alert" || msg == "update" }
}

pub fn message_key(sender: String, identifier: String) -> String {
  string.trim(sender) <> "," <> string.trim(identifier)
}

pub fn public_id(source: String, source_id: String) -> String {
  source <> ":" <> source_id
}

pub fn parse_references(references: Option(String)) -> List(String) {
  case references {
    None -> []
    Some(raw) -> {
      raw
      |> string.split("\n")
      |> list.flat_map(string.split(_, " "))
      |> list.flat_map(string.split(_, "\t"))
      |> list.flat_map(string.split(_, "\r"))
      |> list.filter_map(fn(token) {
        let trimmed = string.trim(token)
        case trimmed == "" {
          True -> Error(Nil)
          False ->
            case string.split(trimmed, ",") {
              [sender, identifier, sent] -> {
                let s = string.trim(sender)
                let i = string.trim(identifier)
                let t = string.trim(sent)
                case s != "" && i != "" && t != "" {
                  True -> Ok(s <> "," <> i)
                  False -> Error(Nil)
                }
              }
              _ -> Error(Nil)
            }
        }
      })
      |> list.unique
    }
  }
}

pub fn canonicalize_severity(s: String) -> String {
  case string.lowercase(string.trim(s)) {
    "extreme" -> "Extreme"
    "severe" -> "Severe"
    "moderate" -> "Moderate"
    "minor" -> "Minor"
    _ -> "Unknown"
  }
}

pub fn severity_rank(s: String) -> Int {
  case string.lowercase(string.trim(s)) {
    "extreme" -> 4
    "severe" -> 3
    "moderate" -> 2
    "minor" -> 1
    _ -> 0
  }
}

pub fn canonicalize_urgency(u: String) -> String {
  case string.lowercase(string.trim(u)) {
    "immediate" -> "Immediate"
    "expected" -> "Expected"
    "future" -> "Future"
    "past" -> "Past"
    _ -> "Unknown"
  }
}

pub fn canonicalize_certainty(c: String) -> String {
  case string.lowercase(string.trim(c)) {
    "observed" -> "Observed"
    "likely" -> "Likely"
    "very likely" -> "Likely"
    "possible" -> "Possible"
    "unlikely" -> "Unlikely"
    _ -> "Unknown"
  }
}

pub fn effective_info_language(info: models_cap.CapInfo) -> String {
  case info.language {
    Some(lang) -> {
      let trimmed = string.trim(lang)
      case trimmed {
        "" -> "en-US"
        val -> val
      }
    }
    None -> "en-US"
  }
}

pub fn display_language(infos: List(models_cap.CapInfo)) -> String {
  let en_info =
    list.find(infos, fn(info) {
      raa.primary_language_subtag(Some(effective_info_language(info))) == "en"
    })
  case en_info {
    Ok(info) -> effective_info_language(info)
    Error(Nil) ->
      case list.first(infos) {
        Ok(first) -> effective_info_language(first)
        Error(Nil) -> "en-US"
      }
  }
}

pub fn candidate_infos(
  infos: List(models_cap.CapInfo),
) -> List(models_cap.CapInfo) {
  let disp = display_language(infos)
  let target_subtag = raa.primary_language_subtag(Some(disp))
  list.filter(infos, fn(info) {
    raa.primary_language_subtag(Some(effective_info_language(info)))
    == target_subtag
  })
}

pub fn choose_info(
  candidates: List(models_cap.CapInfo),
) -> Option(models_cap.CapInfo) {
  list.fold(candidates, None, fn(best: Option(models_cap.CapInfo), candidate) {
    case best {
      None -> Some(candidate)
      Some(current) ->
        case
          severity_rank(candidate.severity) > severity_rank(current.severity)
        {
          True -> Some(candidate)
          False -> Some(current)
        }
    }
  })
}

pub fn compute_active_until(
  chosen_expires: Option(String),
  sent: Timestamp,
) -> Timestamp {
  case chosen_expires {
    Some(s) ->
      case parse_rfc3339(s) {
        Ok(t) -> t
        Error(Nil) -> timestamp.add(sent, duration.hours(24))
      }
    None -> timestamp.add(sent, duration.hours(24))
  }
}

pub fn compute_message_expires_at(
  msg: models_cap.CapMessage,
) -> Result(Timestamp, String) {
  case parse_rfc3339(msg.sent) {
    Error(Nil) -> Error("invalid sent timestamp in CAP message")
    Ok(sent_time) -> {
      let default_floor = timestamp.add(sent_time, duration.hours(24))
      let parsed_expires =
        msg.info
        |> list.filter_map(fn(i) {
          case i.expires {
            Some(s) -> parse_rfc3339(s)
            None -> Error(Nil)
          }
        })
      let max_time =
        list.fold(parsed_expires, default_floor, fn(latest, t) {
          case timestamp.compare(t, latest) {
            order.Gt -> t
            _ -> latest
          }
        })
      Ok(max_time)
    }
  }
}

pub fn normalize_alert(
  msg: models_cap.CapMessage,
  owner_source_id: String,
  country_iso3: String,
) -> Result(NormalizedAlert, NormalizeError) {
  case should_normalize(msg.status, msg.scope, msg.msg_type) {
    False -> Error(NotEligible)
    True ->
      case parse_rfc3339(msg.sent) {
        Error(Nil) -> Error(InvalidSent)
        Ok(sent_time) -> {
          let candidates = candidate_infos(msg.info)
          case choose_info(candidates) {
            None -> Error(NoInfo)
            Some(chosen) -> {
              let area_descs =
                candidates
                |> list.flat_map(fn(i) { i.area })
                |> list.map(fn(a) { string.trim(a.area_desc) })
                |> list.filter(fn(d) { d != "" })
                |> list.unique

              let area_desc = case area_descs {
                [] -> "Unknown area"
                _ -> string.join(area_descs, "; ")
              }

              let geocodes =
                candidates
                |> list.flat_map(fn(i) { i.area })
                |> list.flat_map(fn(a) { a.geocode })
                |> list.unique

              let candidate_areas =
                candidates
                |> list.flat_map(fn(i) { i.area })

              let geom = cap_geometry.areas_to_geojson(candidate_areas)
              let active_until = compute_active_until(chosen.expires, sent_time)
              let reference_keys = parse_references(msg.references)
              let message_type = case
                string.lowercase(string.trim(msg.msg_type))
              {
                "update" -> "Update"
                _ -> "Alert"
              }

              Ok(NormalizedAlert(
                source: owner_source_id,
                source_id: message_key(msg.sender, msg.identifier),
                sender: Some(msg.sender),
                sender_name: chosen.sender_name,
                identifier: Some(msg.identifier),
                message_type:,
                event: chosen.event,
                category: chosen.category,
                severity: canonicalize_severity(chosen.severity),
                urgency: canonicalize_urgency(chosen.urgency),
                certainty: canonicalize_certainty(chosen.certainty),
                headline: chosen.headline,
                description: chosen.description,
                instruction: chosen.instruction,
                web: chosen.web,
                contact: chosen.contact,
                language: Some(effective_info_language(chosen)),
                area_desc:,
                geocodes:,
                countries: case country_iso3 {
                  "" -> []
                  _ -> [country_iso3]
                },
                geom:,
                reference_keys:,
                sent: Some(sent_time),
                effective: option.then(chosen.effective, fn(s) {
                  option.from_result(parse_rfc3339(s))
                }),
                onset: option.then(chosen.onset, fn(s) {
                  option.from_result(parse_rfc3339(s))
                }),
                expires: option.then(chosen.expires, fn(s) {
                  option.from_result(parse_rfc3339(s))
                }),
                ends: None,
                active_until:,
                ended_at: None,
                end_reason: None,
                superseded_by: None,
              ))
            }
          }
        }
      }
  }
}

pub fn resolve_supersede_and_cancel(
  incoming_msg_type: String,
  incoming_status: String,
  incoming_public_id: String,
  referencing_messages: List(StoredMessageRef),
  referenced_active_rows: List(ActiveAlertRef),
  now: Timestamp,
) -> ResolutionResult {
  let actual_referencing =
    list.filter(referencing_messages, fn(m) {
      string.lowercase(string.trim(m.status)) == "actual"
    })

  let incoming_ending = {
    let update_ref =
      list.find(actual_referencing, fn(m) {
        let t = string.lowercase(string.trim(m.msg_type))
        let is_public = string.lowercase(string.trim(m.scope)) == "public"
        { t == "update" || t == "alert" } && m.normalized && is_public
      })
    case update_ref {
      Ok(m) ->
        InsertedEnded(
          ended_at: now,
          end_reason: "superseded",
          superseded_by: Some(m.public_id),
        )
      Error(Nil) -> {
        let cancel_ref =
          list.find(actual_referencing, fn(m) {
            string.lowercase(string.trim(m.msg_type)) == "cancel"
          })
        case cancel_ref {
          Ok(_) ->
            InsertedEnded(
              ended_at: now,
              end_reason: "cancelled",
              superseded_by: None,
            )
          Error(Nil) -> NotEnded
        }
      }
    }
  }

  let norm_msg_type = string.lowercase(string.trim(incoming_msg_type))
  let is_incoming_actual =
    string.lowercase(string.trim(incoming_status)) == "actual"

  let rows_to_end = case is_incoming_actual {
    False -> []
    True ->
      case norm_msg_type {
        "alert" | "update" ->
          list.map(referenced_active_rows, fn(row) {
            EndAlertAction(
              source: row.source,
              source_id: row.source_id,
              ended_at: now,
              end_reason: "superseded",
              superseded_by: Some(incoming_public_id),
            )
          })
        "cancel" ->
          list.map(referenced_active_rows, fn(row) {
            EndAlertAction(
              source: row.source,
              source_id: row.source_id,
              ended_at: now,
              end_reason: "cancelled",
              superseded_by: None,
            )
          })
        _ -> []
      }
  }

  ResolutionResult(incoming_ending:, rows_to_end:)
}

pub fn make_incoming_record(
  msg: models_cap.CapMessage,
  payload: a,
) -> Result(record.Incoming(a), String) {
  case parse_rfc3339(msg.sent) {
    Ok(t) -> {
      let key = record.Key("cap", message_key(msg.sender, msg.identifier))
      let #(sec, nsec) = timestamp.to_unix_seconds_and_nanoseconds(t)
      let revision = sec * 1000 + nsec / 1_000_000
      Ok(record.Incoming(key:, revision:, payload:))
    }
    Error(Nil) -> Error("invalid sent timestamp in CAP message")
  }
}

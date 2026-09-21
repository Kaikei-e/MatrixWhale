import domain/cap
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

pub const max_retry_attempts = 5

pub const retry_interval_seconds = 300

pub type ItemState {
  Pending
  Fetching
  Ingested
  Failed
  Terminal
}

pub fn item_state_to_string(state: ItemState) -> String {
  case state {
    Pending -> "pending"
    Fetching -> "fetching"
    Ingested -> "ingested"
    Failed -> "failed"
    Terminal -> "terminal"
  }
}

pub fn string_to_item_state(s: String) -> ItemState {
  case s {
    "fetching" -> Fetching
    "ingested" -> Ingested
    "failed" -> Failed
    "terminal" -> Terminal
    _ -> Pending
  }
}

pub fn is_live_status(status: String) -> Bool {
  status == "通常"
}

pub fn is_cancel(info_type: String) -> Bool {
  info_type == "取消"
}

pub fn is_correction(info_type: String) -> Bool {
  info_type == "訂正"
}

pub fn is_publication(info_type: String) -> Bool {
  info_type == "発表"
}

pub fn is_normalizable_info_type(info_type: String) -> Bool {
  info_type == "発表" || info_type == "訂正" || info_type == "取消"
}

pub fn is_active_alert_status(status: String) -> Bool {
  status == "発表"
  || status == "継続"
  || status == "特別警報から警報"
  || status == "警報から注意報"
}

pub fn is_supported_earthquake_report(title: String) -> Bool {
  title == "震源に関する情報" || title == "震源・震度に関する情報"
}

pub fn is_supported_alert_report(title: String) -> Bool {
  title == "気象特別警報・警報・注意報" || title == "気象警報・注意報"
}

pub fn is_terminal_http_status(status: Int) -> Bool {
  status == 400 || status == 404 || status == 410
}

pub fn is_terminal_error(http_status: Int, error: Option(String)) -> Bool {
  is_terminal_http_status(http_status)
  || { http_status == 200 && option.is_some(error) }
}

pub fn parse_rfc3339(iso: String) -> Result(Timestamp, Nil) {
  cap.parse_rfc3339(iso)
}

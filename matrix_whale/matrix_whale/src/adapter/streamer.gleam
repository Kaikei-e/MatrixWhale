import adapter/alert_hub.{type HubMsg, type SSEMessage, Emit, Heartbeat}
import adapter/context.{type Context}
import adapter/earthquake_hub
import domain/alert
import domain/event
import domain/source
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import mist
import repository/alert_reader
import repository/earthquake_reader
import wisp

type SSEState {
  SSEState(subscriber_id: Int, hub: Subject(HubMsg), sent_retry: Bool)
}

type EarthquakeSSEState {
  EarthquakeSSEState(
    id: Int,
    hub: Subject(earthquake_hub.EarthquakeHubMsg),
    sent_retry: Bool,
  )
}

pub fn streamer(ctx: Context) {
  wisp.log_info("Starting alert streamer")

  let assert Ok(_) =
    fn(req) { router(req, ctx) }
    |> mist.new
    |> mist.port(8080)
    |> mist.bind("0.0.0.0")
    |> mist.start()

  wisp.log_info("Alert streamer started")
  process.sleep_forever()
}

fn router(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["api", "v1", "streamer", "health"] -> health_response()
    ["api", "v1", "alerts", "active"] -> active_response(ctx)
    ["api", "v1", "alerts", "stream"] -> stream_response(req, ctx)
    ["api", "v1", "alerts", "search"] -> search_response(req, ctx)
    ["api", "v1", "alerts", "history"] -> history_response(req, ctx)
    ["api", "v1", "earthquakes", "recent"] -> earthquakes_response(req, ctx)
    ["api", "v1", "earthquakes", "stream"] ->
      case req.method {
        http.Get -> earthquake_stream_response(req, ctx)
        _ ->
          response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    ["api", "v1", "pipeline", "status"] -> pipeline_status_response(ctx)
    ["api", "v1", "sources"] -> sources_response()
    _ -> not_found_response()
  }
}

fn earthquake_stream_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> earthquake_stream_response_actual(req, ctx)
    _ -> response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn earthquake_stream_response_actual(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let since = request.get_header(req, "last-event-id") |> option.from_result
  mist.server_sent_events(
    req,
    response.new(200),
    init: fn(subject) {
      EarthquakeSSEState(
        id: earthquake_hub.subscribe(ctx.earthquake_hub, subject, since),
        hub: ctx.earthquake_hub,
        sent_retry: False,
      )
    },
    loop: fn(
      state: EarthquakeSSEState,
      message: earthquake_hub.SSEMessage,
      conn: mist.SSEConnection,
    ) -> actor.Next(EarthquakeSSEState, earthquake_hub.SSEMessage) {
      let event = case message {
        earthquake_hub.Emit(name, id, data) ->
          mist.event(string_tree.from_string(data))
          |> mist.event_name(name)
          |> mist.event_id(id)
        earthquake_hub.Heartbeat(id) ->
          mist.event(string_tree.from_string("{}"))
          |> mist.event_name("heartbeat")
          |> mist.event_id(id)
        earthquake_hub.Resync(id) ->
          mist.event(string_tree.from_string("{\"reason\":\"event_gap\"}"))
          |> mist.event_name("resync")
          |> mist.event_id(id)
      }
      let event = case state.sent_retry {
        True -> event
        False -> mist.event_retry(event, 3000)
      }
      case mist.send_event(conn, event) {
        Ok(_) -> actor.continue(EarthquakeSSEState(..state, sent_retry: True))
        Error(_) -> {
          earthquake_hub.unsubscribe(state.hub, state.id)
          actor.stop()
        }
      }
    },
  )
}

pub fn earthquakes_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> earthquakes_get_response(req, ctx)
    _ -> response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn earthquakes_get_response(
  req: Request(connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let hours = case list.key_find(query, "hours") {
    Ok(value) ->
      int.parse(value)
      |> result.map_error(fn(_) { "hours must be an integer 1..168" })
    Error(_) -> Ok(24)
  }
  case hours {
    Error(error) ->
      json_response(400, json.object([#("error", json.string(error))]))
    Ok(hours) ->
      case parse_minmag(query |> list.key_find("minmag") |> result.unwrap("")) {
        Error(error) ->
          json_response(400, json.object([#("error", json.string(error))]))
        Ok(minmag) ->
          case
            parse_type(
              query |> list.key_find("type") |> result.unwrap("earthquake"),
            )
          {
            Error(error) ->
              json_response(400, json.object([#("error", json.string(error))]))
            Ok(type_) ->
              case hours < 1 || hours > 168 {
                True ->
                  json_response(
                    400,
                    json.object([
                      #("error", json.string("hours must be 1..168")),
                    ]),
                  )
                False ->
                  case earthquake_reader.recent(hours, minmag, type_, ctx.db) {
                    Error(error) -> error_response(error)
                    Ok(rows) ->
                      etag_json_response(
                        req,
                        json.object([
                          #("earthquakes", json.array(rows, event.to_json)),
                        ]),
                      )
                  }
              }
          }
      }
  }
}

pub fn parse_minmag(
  value: String,
) -> Result(earthquake_reader.MagnitudeFilter, String) {
  case value {
    "" -> Ok(earthquake_reader.Minimum(2.5))
    "all" -> Ok(earthquake_reader.AllMagnitudes)
    value ->
      case float.parse(value) {
        Ok(value) -> Ok(earthquake_reader.Minimum(value))
        Error(_) -> Error("minmag must be a number or all")
      }
  }
}

pub fn parse_type(
  value: String,
) -> Result(earthquake_reader.TypeFilter, String) {
  case value {
    "earthquake" -> Ok(earthquake_reader.EarthquakesOnly)
    "all" -> Ok(earthquake_reader.AllTypes)
    _ -> Error("type must be earthquake or all")
  }
}

pub fn etag_json_response(
  req: Request(connection),
  body: json.Json,
) -> Response(mist.ResponseData) {
  let text = json.to_string(body)
  let etag =
    "\""
    <> {
      crypto.hash(crypto.Sha256, bit_array.from_string(text))
      |> bit_array.base16_encode
    }
    <> "\""
  case request.get_header(req, "if-none-match") {
    Ok(value) ->
      case if_none_match_matches(value, etag) {
        True ->
          response.new(304)
          |> response.set_header("etag", etag)
          |> response.set_header("cache-control", "no-cache")
          |> response.set_body(mist.Bytes(bytes_tree.new()))
        False -> etag_body_response(etag, text)
      }
    _ -> etag_body_response(etag, text)
  }
}

fn etag_body_response(
  etag: String,
  text: String,
) -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_header("etag", etag)
  |> response.set_header("cache-control", "no-cache")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

pub fn if_none_match_matches(value: String, etag: String) -> Bool {
  value
  |> string.split(",")
  |> list.any(fn(candidate) {
    let candidate = string.trim(candidate)
    candidate == "*" || candidate == etag || candidate == "W/" <> etag
  })
}

fn active_response(ctx: Context) -> Response(mist.ResponseData) {
  case alert_reader.list_active(ctx.db) {
    Ok(rows) -> json_response(200, json.array(rows, alert.to_json))
    Error(err) -> error_response(err)
  }
}

fn search_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let query =
    request.get_query(req)
    |> result.unwrap([])
    |> list.key_find("q")
    |> result.unwrap("")

  case alert_reader.search(query, ctx.db) {
    Ok(rows) -> json_response(200, json.array(rows, alert.to_json))
    Error(err) -> error_response(err)
  }
}

fn history_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let hours =
    request.get_query(req)
    |> result.unwrap([])
    |> list.key_find("hours")
    |> result.try(int.parse)
    |> result.unwrap(24)

  case alert_reader.history(hours, ctx.db) {
    Ok(buckets) ->
      json_response(
        200,
        json.array(buckets, alert_reader.history_bucket_to_json),
      )
    Error(err) -> error_response(err)
  }
}

fn pipeline_status_response(ctx: Context) -> Response(mist.ResponseData) {
  let stats = alert_hub.get_stats(ctx.hub)

  case alert_reader.count_active_by_severity(ctx.db) {
    Ok(active_by_severity) ->
      json_response(
        200,
        json.object([
          #("last_fetch_at", json.nullable(stats.last_fetch_at, json.string)),
          #("last_http_status", json.nullable(stats.last_http_status, json.int)),
          #("last_received", json.int(stats.last_received)),
          #("last_decoded", json.int(stats.last_decoded)),
          #("last_dropped", json.int(stats.last_dropped)),
          #("last_write_at", json.nullable(stats.last_write_at, json.string)),
          #("last_new", json.int(stats.last_new)),
          #("last_updated", json.int(stats.last_updated)),
          #("last_ended", json.int(stats.last_ended)),
          #("sse_clients", json.int(stats.sse_clients)),
          #("sources", alert_hub.source_stats_to_json(stats.source_stats)),
          #(
            "active_by_severity",
            alert_reader.severity_counts_to_json(active_by_severity),
          ),
        ]),
      )
    Error(err) -> error_response(err)
  }
}

fn sources_response() -> Response(mist.ResponseData) {
  json_response(
    200,
    json.object([
      #("sources", json.array(source.all, source.to_json)),
    ]),
  )
}

fn stream_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let since_id =
    request.get_header(req, "last-event-id")
    |> result.try(int.parse)
    |> option.from_result

  mist.server_sent_events(
    req,
    response.new(200),
    init: fn(subj) {
      let subscriber_id = alert_hub.subscribe(ctx.hub, subj, since_id)
      SSEState(subscriber_id: subscriber_id, hub: ctx.hub, sent_retry: False)
    },
    loop: fn(state: SSEState, message: SSEMessage, conn: mist.SSEConnection) -> actor.Next(
      SSEState,
      SSEMessage,
    ) {
      let event = case message {
        Emit(event_name, id, data) ->
          mist.event(string_tree.from_string(data))
          |> mist.event_name(event_name)
          |> mist.event_id(int.to_string(id))
        Heartbeat(last_id) ->
          mist.event(string_tree.from_string("{}"))
          |> mist.event_name("heartbeat")
          |> mist.event_id(int.to_string(last_id))
      }

      case send_event(conn, state, event) {
        Ok(new_state) -> actor.continue(new_state)
        Error(_) -> {
          alert_hub.unsubscribe(state.hub, state.subscriber_id)
          actor.stop()
        }
      }
    },
  )
}

fn send_event(
  conn: mist.SSEConnection,
  state: SSEState,
  event: mist.SSEEvent,
) -> Result(SSEState, Nil) {
  let event = case state.sent_retry {
    True -> event
    False -> mist.event_retry(event, 3000)
  }

  mist.send_event(conn, event)
  |> result.map(fn(_) { SSEState(..state, sent_retry: True) })
}

fn health_response() -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("system is alive")))
}

fn not_found_response() -> Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn error_response(message: String) -> Response(mist.ResponseData) {
  wisp.log_error(message)
  json_response(500, json.object([#("error", json.string(message))]))
}

fn json_response(status: Int, body: json.Json) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

import adapter/alert_hub.{type HubMsg, type SSEMessage, Emit, Heartbeat}
import adapter/context.{type Context}
import domain/alert
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string_tree
import mist
import repository/alert_reader
import wisp

type SSEState {
  SSEState(subscriber_id: Int, hub: Subject(HubMsg), sent_retry: Bool)
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
    ["api", "v1", "pipeline", "status"] -> pipeline_status_response(ctx)
    _ -> not_found_response()
  }
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
          #(
            "active_by_severity",
            alert_reader.severity_counts_to_json(active_by_severity),
          ),
        ]),
      )
    Error(err) -> error_response(err)
  }
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

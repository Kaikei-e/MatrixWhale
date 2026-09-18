import adapter/alert_hub
import adapter/context.{type Context}
import controller/gdacs_controller
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import message/reciever/models/earthquake_feature.{type PollMeta}
import message/reciever/models/gdacs
import repository/gdacs_geometry_writer
import wisp.{type Request, type Response}

const default_pending_limit = 20

const max_pending_limit = 100

pub fn gdacs_data_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> gdacs_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn gdacs_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 17 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case gdacs.decode_body(body) {
    Error(error) -> error_response(400, "invalid GDACS envelope: " <> error)
    Ok(#(meta, features, received, decode_dropped)) -> {
      case gdacs_controller.process(features, ctx) {
        Ok(result) -> {
          let deduped = result.repeats + result.unchanged + result.stale
          let written = result.new + result.updated
          alert_hub.record_source(
            ctx.hub,
            "gdacs",
            alert_hub.SourceWrite(
              http_status: meta_http_status(meta),
              received: received,
              written: written,
              dropped: decode_dropped,
              bytes: meta_bytes(meta),
              dedup_intake: result.repeats,
              dedup_unchanged: result.unchanged,
              dedup_stale: result.stale,
              matched: 0,
            ),
          )
          ack_response(
            received,
            deduped,
            written,
            decode_dropped,
            string.inspect(result.new)
              <> " new, "
              <> string.inspect(result.updated)
              <> " updated",
          )
        }
        Error(error) -> error_response(503, error)
      }
    }
  }
}

pub fn gdacs_geometry_pending_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Get -> gdacs_geometry_pending_get(req, ctx)
    _ -> wisp.response(405)
  }
}

fn gdacs_geometry_pending_get(req: Request, ctx: Context) -> Response {
  let limit =
    wisp.get_query(req)
    |> list.key_find("limit")
    |> result.try(int.parse)
    |> result.unwrap(default_pending_limit)
    |> int.clamp(1, max_pending_limit)

  case gdacs_geometry_writer.pending(limit, ctx.db) {
    Ok(rows) ->
      wisp.json_response(
        json.to_string(
          json.object([#("episodes", json.array(rows, episode_key_to_json))]),
        ),
        200,
      )
    Error(error) -> error_response(500, error)
  }
}

fn episode_key_to_json(row: #(String, Int, Int)) -> json.Json {
  json.object([
    #("eventtype", json.string(row.0)),
    #("eventid", json.int(row.1)),
    #("episodeid", json.int(row.2)),
  ])
}

pub fn gdacs_geometry_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> gdacs_geometry_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn gdacs_geometry_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 17 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case gdacs.decode_geometry_body(body) {
    Error(error) ->
      error_response(400, "invalid GDACS geometry envelope: " <> error)
    Ok(#(meta, results, received, decode_dropped)) ->
      case
        gdacs_controller.process_geometry(results, meta_backfill(meta), ctx)
      {
        Ok(ack) -> {
          let dropped = decode_dropped + ack.dropped
          ack_response(
            received,
            ack.deduped,
            ack.written,
            dropped,
            string.inspect(ack.written) <> " geometry applied",
          )
        }
        Error(error) -> error_response(503, error)
      }
  }
}

fn ack_response(
  received: Int,
  deduped: Int,
  written: Int,
  dropped: Int,
  message: String,
) -> Response {
  wisp.json_response(
    json.to_string(
      json.object([
        #("received", json.int(received)),
        #("deduped", json.int(deduped)),
        #("written", json.int(written)),
        #("dropped", json.int(dropped)),
        #("message", json.string(message)),
      ]),
    ),
    200,
  )
}

fn error_response(status: Int, message: String) -> Response {
  wisp.json_response(
    json.to_string(json.object([#("error", json.string(message))])),
    status,
  )
}

fn meta_backfill(meta: Option(PollMeta)) -> Bool {
  case meta {
    option.Some(m) -> m.backfill
    option.None -> False
  }
}

fn meta_http_status(meta: Option(PollMeta)) -> Int {
  case meta {
    option.Some(m) -> m.http_status
    option.None -> 200
  }
}

fn meta_bytes(meta: Option(PollMeta)) -> Int {
  case meta {
    option.Some(m) -> m.bytes
    option.None -> 0
  }
}

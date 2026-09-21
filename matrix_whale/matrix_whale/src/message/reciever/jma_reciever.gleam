import adapter/context.{type Context}
import controller/jma_controller
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import message/reciever/models/jma as models_jma
import repository/jma_item_writer.{type PendingItem}
import wisp.{type Request, type Response}

const default_pending_limit = 50

const min_pending_limit = 1

const max_pending_limit = 200

pub fn index_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> index_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn index_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 16 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case models_jma.decode_index_body(body) {
    Error(error) -> error_response(400, "invalid index envelope: " <> error)
    Ok(#(meta, items, received, decode_dropped)) -> {
      case
        jma_controller.process_index(meta, items, received, decode_dropped, ctx)
      {
        Ok(ack) ->
          ack_response(
            ack.received,
            ack.deduped,
            ack.written,
            ack.dropped,
            ack.message,
          )
        Error(error) -> error_response(503, error)
      }
    }
  }
}

pub fn pending_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Get -> pending_get_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn pending_get_handler(req: Request, ctx: Context) -> Response {
  let limit =
    wisp.get_query(req)
    |> list.key_find("limit")
    |> result.try(int.parse)
    |> result.unwrap(default_pending_limit)
    |> int.clamp(min_pending_limit, max_pending_limit)

  case jma_controller.get_pending(limit, ctx) {
    Ok(rows) ->
      wisp.json_response(
        json.to_string(
          json.object([#("items", json.array(rows, pending_item_to_json))]),
        ),
        200,
      )
    Error(error) -> error_response(500, error)
  }
}

fn pending_item_to_json(item: PendingItem) -> json.Json {
  json.object([
    #("item_url", json.string(item.item_url)),
    #("feed_url", json.string(item.feed_url)),
  ])
}

pub fn messages_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> messages_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn messages_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 64 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case models_jma.decode_messages_body(body) {
    Error(error) -> error_response(400, "invalid messages envelope: " <> error)
    Ok(#(meta, items, received, decode_dropped)) -> {
      case
        jma_controller.process_messages(
          items,
          meta,
          received,
          decode_dropped,
          ctx,
        )
      {
        Ok(ack) ->
          ack_response(
            ack.received,
            ack.deduped,
            ack.written,
            ack.dropped,
            ack.message,
          )
        Error(error) -> error_response(503, error)
      }
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

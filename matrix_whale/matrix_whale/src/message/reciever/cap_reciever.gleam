import adapter/context.{type Context}
import controller/cap_controller
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import message/reciever/models/cap as models_cap
import repository/cap_feed_reader.{type SubscribedFeed}
import repository/cap_item_writer.{type PendingItem}
import wisp.{type Request, type Response}

const default_pending_limit = 50

const min_pending_limit = 1

const max_pending_limit = 200

pub fn registry_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> registry_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn registry_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 17 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case models_cap.decode_registry_body(body) {
    Error(error) -> error_response(400, "invalid registry envelope: " <> error)
    Ok(#(_meta, items, received, decode_dropped)) -> {
      case
        cap_controller.process_registry(items, received, decode_dropped, ctx)
      {
        Ok(ack) ->
          ack_response(
            ack.received,
            ack.deduped,
            ack.written,
            ack.dropped,
            int.to_string(ack.written) <> " authorities written",
          )
        Error(error) -> error_response(422, error)
      }
    }
  }
}

pub fn feeds_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Get -> feeds_get_handler(ctx)
    _ -> wisp.response(405)
  }
}

fn feeds_get_handler(ctx: Context) -> Response {
  case cap_controller.get_feeds(ctx) {
    Ok(feeds) ->
      wisp.json_response(
        json.to_string(
          json.object([#("feeds", json.array(feeds, subscribed_feed_to_json))]),
        ),
        200,
      )
    Error(error) -> error_response(500, error)
  }
}

fn subscribed_feed_to_json(f: SubscribedFeed) -> json.Json {
  json.object([
    #("url", json.string(f.url)),
    #("poll_interval_seconds", json.int(f.poll_interval_seconds)),
  ])
}

pub fn index_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> index_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn index_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 17 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case models_cap.decode_index_body(body) {
    Error(error) -> error_response(400, "invalid index envelope: " <> error)
    Ok(#(meta, items, received, decode_dropped)) -> {
      let feed_url = option.then(meta, fn(m) { m.feed_url })
      case
        cap_controller.process_index(
          feed_url,
          meta,
          items,
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
            int.to_string(ack.written) <> " items written",
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

  case cap_controller.get_pending(limit, ctx) {
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
    #("cap_url", json.string(item.cap_url)),
    #("feed_url", json.string(item.feed_url)),
  ])
}

pub fn alerts_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> alerts_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn alerts_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 64 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case models_cap.decode_alerts_body(body) {
    Error(error) -> error_response(400, "invalid alerts envelope: " <> error)
    Ok(#(meta, features, received, decode_dropped)) -> {
      case
        cap_controller.process_alerts(
          features,
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

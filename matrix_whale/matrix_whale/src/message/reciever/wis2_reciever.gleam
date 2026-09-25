import adapter/context.{type Context}
import controller/wis2_controller
import domain/wis2
import domain/wis2_observation
import gleam/http
import gleam/json
import wisp.{type Request, type Response}

pub fn cap_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> cap_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn cap_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 64 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case wis2.decode_cap_body(body) {
    Error(error) -> error_response(400, "invalid wis2 cap envelope: " <> error)
    Ok(#(meta, features, received, decode_dropped)) -> {
      case
        wis2_controller.process_cap(
          meta,
          features,
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

pub fn health_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> health_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn health_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 16 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case wis2.decode_health_body(body) {
    Error(error) ->
      error_response(400, "invalid wis2 health envelope: " <> error)
    Ok(#(meta, features, received, decode_dropped)) -> {
      case
        wis2_controller.process_health(
          meta,
          features,
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

pub fn tc_tracks_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> tc_tracks_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn tc_tracks_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 64 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case wis2.decode_tc_tracks_body(body) {
    Error(error) ->
      error_response(400, "invalid wis2 tc_tracks envelope: " <> error)
    Ok(#(meta, features, received, decode_dropped)) -> {
      case
        wis2_controller.process_tc_tracks(
          meta,
          features,
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

pub fn observations_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> observations_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn observations_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 64 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case wis2_observation.decode_observations_body(body) {
    Error(error) ->
      error_response(400, "invalid wis2 observations envelope: " <> error)
    Ok(#(meta, features, received, decode_dropped)) -> {
      case
        wis2_controller.process_observations(
          meta,
          features,
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

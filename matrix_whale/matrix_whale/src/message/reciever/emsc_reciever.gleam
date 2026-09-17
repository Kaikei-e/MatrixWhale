import adapter/alert_hub
import adapter/context.{type Context}
import controller/earthquake_controller
import domain/source
import gleam/http
import gleam/json
import gleam/option
import gleam/string
import message/reciever/models/emsc
import wisp.{type Request, type Response}

pub fn emsc_data_handler(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Post -> emsc_post_handler(req, ctx)
    _ -> wisp.response(405)
  }
}

fn emsc_post_handler(req: Request, ctx: Context) -> Response {
  let req = wisp.set_max_body_size(req, 17 * 1024 * 1024)
  use body <- wisp.require_json(req)
  case emsc.decode_body(body) {
    Error(error) ->
      wisp.json_response(
        json.to_string(
          json.object([
            #("error", json.string("invalid EMSC envelope: " <> error)),
          ]),
        ),
        400,
      )
    Ok(#(meta, features, received, decode_dropped)) -> {
      let backfill = case meta {
        option.Some(meta) -> meta.backfill
        option.None -> False
      }
      let http_status = case meta {
        option.Some(meta) -> meta.http_status
        option.None -> 200
      }
      let bytes = case meta {
        option.Some(meta) -> meta.bytes
        option.None -> 0
      }
      case earthquake_controller.process(source.emsc, features, backfill, ctx) {
        Ok(result) -> {
          let dropped = decode_dropped + result.expired
          let deduped = result.repeats + result.unchanged + result.stale
          let written = result.new + result.updated
          alert_hub.record_source(
            ctx.hub,
            "emsc",
            alert_hub.SourceWrite(
              http_status: http_status,
              received: received,
              written: written,
              dropped: dropped,
              bytes: bytes,
              dedup_intake: result.repeats,
              dedup_unchanged: result.unchanged,
              dedup_stale: result.stale,
              matched: result.matched,
            ),
          )
          wisp.json_response(
            json.to_string(
              json.object([
                #("received", json.int(received)),
                #("deduped", json.int(deduped)),
                #("written", json.int(written)),
                #("dropped", json.int(dropped)),
                #(
                  "message",
                  json.string(
                    string.inspect(result.new)
                    <> " new, "
                    <> string.inspect(result.updated)
                    <> " updated",
                  ),
                ),
              ]),
            ),
            200,
          )
        }
        Error(error) ->
          wisp.json_response(
            json.to_string(json.object([#("error", json.string(error))])),
            503,
          )
      }
    }
  }
}

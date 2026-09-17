import adapter/alert_hub
import adapter/context.{type Context}
import controller/noaa_controller.{noaa_controller}
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import message/reciever/models/noaa
import wisp.{type Request, type Response}

pub fn noaa_data_handler(req: Request, ctx: Context) -> Response {
  use body <- wisp.require_json(req)

  let #(poll_meta, features, received, dropped) = noaa.decode_body(body)

  case poll_meta {
    option.Some(meta) -> alert_hub.record_poll(ctx.hub, meta)
    option.None -> Nil
  }
  alert_hub.record_decoded(ctx.hub, list.length(features), dropped)

  // A complete, successful poll is the only time it is safe to end alerts
  // that are missing from this batch - a partial or failed poll must not be
  // treated as "these alerts are gone".
  let run_ended_sweep = case poll_meta {
    option.Some(meta) -> meta.http_status == 200
    option.None -> received >= 1
  }

  wisp.log_info(
    "Received "
    <> string.inspect(received)
    <> " features, decoded "
    <> string.inspect(list.length(features))
    <> ", dropped "
    <> string.inspect(dropped),
  )

  let result_message = case noaa_controller(features, run_ended_sweep, ctx) {
    Ok(#(message, new_count, updated_count)) -> {
      let bytes = case poll_meta {
        option.Some(meta) -> meta.bytes
        option.None -> 0
      }
      alert_hub.record_source(
        ctx.hub,
        "noaa",
        case poll_meta {
          option.Some(meta) -> meta.http_status
          option.None -> 0
        },
        received,
        received - dropped - new_count - updated_count,
        new_count + updated_count,
        dropped,
        bytes,
      )
      message
    }
    Error(err) -> {
      wisp.log_error("Error processing features: " <> err)
      "Error: " <> err
    }
  }

  wisp.json_response(
    json.object([
      #("received", json.int(received)),
      #("decoded", json.int(list.length(features))),
      #("dropped", json.int(dropped)),
      #("message", json.string(result_message)),
    ])
      |> json.to_string,
    200,
  )
}

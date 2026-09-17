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

  let #(poll_meta, features, received, decode_dropped) = noaa.decode_body(body)

  case poll_meta {
    option.Some(meta) -> alert_hub.record_poll(ctx.hub, meta)
    option.None -> Nil
  }
  alert_hub.record_decoded(ctx.hub, list.length(features), decode_dropped)

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
    <> string.inspect(decode_dropped),
  )

  case noaa_controller(features, run_ended_sweep, ctx) {
    Ok(result) -> {
      let dropped = decode_dropped + result.test_dropped
      let deduped = result.repeats + result.unchanged + result.stale
      let written = result.new + result.updated
      let bytes = case poll_meta {
        option.Some(meta) -> meta.bytes
        option.None -> 0
      }
      let http_status = case poll_meta {
        option.Some(meta) -> meta.http_status
        option.None -> 0
      }

      alert_hub.record_source(
        ctx.hub,
        "noaa",
        alert_hub.SourceWrite(
          http_status: http_status,
          received: received,
          written: written,
          dropped: dropped,
          bytes: bytes,
          dedup_intake: result.repeats,
          dedup_unchanged: result.unchanged,
          dedup_stale: result.stale,
          matched: 0,
        ),
      )

      wisp.json_response(
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
              <> " updated, "
              <> string.inspect(result.ended)
              <> " ended",
            ),
          ),
        ])
          |> json.to_string,
        200,
      )
    }
    Error(error) -> {
      wisp.log_error("Error processing features: " <> error)
      wisp.json_response(
        json.to_string(json.object([#("error", json.string(error))])),
        503,
      )
    }
  }
}

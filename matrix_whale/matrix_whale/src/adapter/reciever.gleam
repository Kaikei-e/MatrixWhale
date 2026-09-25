import adapter/context.{type Context}
import gleam/erlang/process
import gleam/http
import gleam/string_tree
import logs/reciever/usgs_adapter
import message/reciever/cap_reciever
import message/reciever/emsc_reciever
import message/reciever/gdacs_reciever
import message/reciever/jma_reciever
import message/reciever/noaa_reciever
import message/reciever/usgs_reciever
import message/reciever/wis2_reciever
import metrics
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn reciever_main(ctx: Context) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(128)

  let assert Ok(_) =
    wisp_mist.handler(reciever_router(_, ctx), secret_key_base)
    |> mist.new
    |> mist.port(6000)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}

pub fn reciever_router(request: Request, ctx: Context) -> Response {
  let start = metrics.monotonic_now()
  let segments = wisp.path_segments(request)
  let route = metrics.route_template(segments)
  use req <- middleware(request)
  let method = http.method_to_string(req.method)

  let res = case segments {
    ["metrics"] ->
      case req.method {
        http.Get ->
          wisp.response(200)
          |> wisp.set_header(
            "content-type",
            "text/plain; version=0.0.4; charset=utf-8",
          )
          |> wisp.string_body(metrics.render())
        _ -> wisp.response(405)
      }
    ["api", "v1", "health"] -> {
      wisp.json_response(
        string_tree.from_string("system is alive") |> string_tree.to_string,
        200,
      )
    }
    ["api", "v1", "logs"] -> usgs_adapter.usgs_logs_handler(req)
    ["api", "v1", "noaa_data", "send"] ->
      noaa_reciever.noaa_data_handler(req, ctx)
    ["api", "v1", "usgs_data", "send"] ->
      usgs_reciever.usgs_data_handler(req, ctx)
    ["api", "v1", "emsc_data", "send"] ->
      emsc_reciever.emsc_data_handler(req, ctx)
    ["api", "v1", "gdacs_data", "send"] ->
      gdacs_reciever.gdacs_data_handler(req, ctx)
    ["api", "v1", "gdacs_data", "geometry", "pending"] ->
      gdacs_reciever.gdacs_geometry_pending_handler(req, ctx)
    ["api", "v1", "gdacs_data", "geometry"] ->
      gdacs_reciever.gdacs_geometry_handler(req, ctx)
    ["api", "v1", "cap_data", "registry"] ->
      cap_reciever.registry_handler(req, ctx)
    ["api", "v1", "cap_data", "feeds"] -> cap_reciever.feeds_handler(req, ctx)
    ["api", "v1", "cap_data", "index"] -> cap_reciever.index_handler(req, ctx)
    ["api", "v1", "cap_data", "pending"] ->
      cap_reciever.pending_handler(req, ctx)
    ["api", "v1", "cap_data", "alerts"] -> cap_reciever.alerts_handler(req, ctx)
    ["api", "v1", "jma_data", "index"] -> jma_reciever.index_handler(req, ctx)
    ["api", "v1", "jma_data", "pending"] ->
      jma_reciever.pending_handler(req, ctx)
    ["api", "v1", "jma_data", "messages"] ->
      jma_reciever.messages_handler(req, ctx)
    ["api", "v1", "wis2_data", "cap"] -> wis2_reciever.cap_handler(req, ctx)
    ["api", "v1", "wis2_data", "health"] ->
      wis2_reciever.health_handler(req, ctx)
    _ -> wisp.response(404)
  }

  let duration = metrics.monotonic_elapsed_seconds(start)
  metrics.observe_http(metrics.Ingest, route, method, res.status, duration)
  res
}

fn middleware(request: Request, handle_request: fn(Request) -> Response) {
  let req = wisp.method_override(request)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  handle_request(req)
}

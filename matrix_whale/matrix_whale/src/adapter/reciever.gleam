import adapter/context.{type Context}
import gleam/erlang/process
import gleam/string_tree
import logs/reciever/noaa_adapter
import message/reciever/noaa_reciever

// import message/streamer/noaa_severity_streamrer
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
    |> mist.start_http()

  process.sleep_forever()
}

fn reciever_router(request: Request, ctx: Context) -> Response {
  use req <- middleware(request)

  case wisp.path_segments(request) {
    ["api", "v1", "health"] -> {
      string_tree.from_string("system is alive") |> wisp.json_response(200)
    }
    ["api", "v1", "logs"] -> noaa_adapter.noaa_logs_handler(req)
    ["api", "v1", "noaa_data", "send"] ->
      noaa_reciever.noaa_data_handler(req, ctx)
    // ["api", "v1", "noaa_data", "stream"] ->
    //   noaa_severity_streamrer.sse_noaa_severity(req, ctx)
    _ -> wisp.response(404)
  }
}

fn middleware(request: Request, handle_request: fn(Request) -> Response) {
  let req = wisp.method_override(request)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  handle_request(req)
}

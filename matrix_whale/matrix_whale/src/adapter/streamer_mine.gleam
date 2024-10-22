import adapter/context.{type Context}
import gleam/erlang/process
import gleam/string_builder
import message/streamer/noaa_severity_streamrer.{sse_noaa_severity}
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn streamer_mine_main(ctx: Context) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(128)

  let assert Ok(_) =
    wisp_mist.handler(streamer_mine_router(_, ctx), secret_key_base)
    |> mist.new
    |> mist.port(8080)
    |> mist.start_http()

  process.sleep_forever()
}

fn streamer_mine_router(request: Request, ctx: Context) -> Response {
  use req <- middleware(request)

  case wisp.path_segments(req) {
    ["api", "v1", "streamer", "health"] ->
      string_builder.from_string("system is alive")
      |> wisp.json_response(200)
    ["api", "v1", "noaa_data2", "noaa_severity"] -> sse_noaa_severity(req, ctx)
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

import gleam/erlang/process
import gleam/string_builder
import logs/reciever/noaa_adapter
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn reciever_main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(128)

  let assert Ok(_) =
    wisp_mist.handler(reciever_router, secret_key_base)
    |> mist.new
    |> mist.port(6000)
    |> mist.start_http()

  process.sleep_forever()
}

pub type Context {
  Context(secret: String)
}

fn reciever_router(request: Request) -> Response {
  use req <- middleware(request)

  case wisp.path_segments(req) {
    ["api", "v1", "health"] -> {
      string_builder.from_string("system is alive") |> wisp.json_response(200)
    }
    ["api", "v1", "logs"] -> noaa_adapter.noaa_logs_handler(req)
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

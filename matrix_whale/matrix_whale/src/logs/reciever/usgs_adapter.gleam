import logs/reciever/noaa_adapter
import wisp.{type Request, type Response}

/// USGS emits the same structured slog envelope as the NOAA adapter. Keep a
/// source-specific entry point so routing and classification can diverge
/// without duplicating the wire decoder.
pub fn usgs_logs_handler(req: Request) -> Response {
  noaa_adapter.noaa_logs_handler(req)
}

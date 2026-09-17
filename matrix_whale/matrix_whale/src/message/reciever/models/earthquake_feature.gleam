import gleam/option.{type Option}

pub type PollMeta {
  PollMeta(
    fetched_at: String,
    http_status: Int,
    feature_count: Int,
    bytes: Int,
    backfill: Bool,
  )
}

pub type IncomingEarthquake {
  IncomingEarthquake(
    source_id: String,
    ids: List(String),
    sources: List(String),
    net: Option(String),
    code: Option(String),
    mag: Option(Float),
    mag_type: Option(String),
    time: Int,
    updated: Int,
    place: Option(String),
    title: Option(String),
    status: Option(String),
    type_: Option(String),
    tsunami: Option(Int),
    sig: Option(Int),
    alert: Option(String),
    mmi: Option(Float),
    cdi: Option(Float),
    felt: Option(Int),
    nst: Option(Int),
    dmin: Option(Float),
    rms: Option(Float),
    gap: Option(Float),
    url: Option(String),
    detail: Option(String),
    lon: Float,
    lat: Float,
    depth: Option(Float),
    raw: String,
  )
}

import gleam/option.{type Option, None, Some}

pub type Source {
  Noaa
  Usgs
  Emsc
  Gdacs
  Cap
  Jma
  Unknown
}

pub fn classify(service: String, explicit_source: Option(String)) -> Source {
  case explicit_source {
    Some(source) -> classify_name(source)
    None -> classify_name(service)
  }
}

fn classify_name(name: String) -> Source {
  case name {
    "noaa" -> Noaa
    "noaa_adapter" -> Noaa
    "usgs" -> Usgs
    "usgs_adapter" -> Usgs
    "emsc" -> Emsc
    "emsc_adapter" -> Emsc
    "gdacs" -> Gdacs
    "gdacs_adapter" -> Gdacs
    "cap" -> Cap
    "cap_adapter" -> Cap
    "jma" -> Jma
    "jma_adapter" -> Jma
    _ -> Unknown
  }
}

pub fn source_name(source: Source) -> String {
  case source {
    Noaa -> "noaa"
    Usgs -> "usgs"
    Emsc -> "emsc"
    Gdacs -> "gdacs"
    Cap -> "cap"
    Jma -> "jma"
    Unknown -> "unknown"
  }
}

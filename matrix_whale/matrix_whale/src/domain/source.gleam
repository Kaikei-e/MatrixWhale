import gleam/json
import gleam/list
import gleam/option.{type Option}

pub type Source {
  Source(
    id: String,
    name: String,
    homepage: Option(String),
    license: String,
    attribution_text: String,
    redistributable: Bool,
    priority: Int,
  )
}

pub const noaa = Source(
  id: "noaa",
  name: "NOAA National Weather Service",
  homepage: option.Some("https://www.weather.gov/"),
  license: "public-domain",
  attribution_text: "Source: NOAA National Weather Service",
  redistributable: True,
  priority: 100,
)

pub const usgs = Source(
  id: "usgs",
  name: "U.S. Geological Survey",
  homepage: option.Some("https://earthquake.usgs.gov/"),
  license: "public-domain",
  attribution_text: "Credit: U.S. Geological Survey",
  redistributable: True,
  priority: 100,
)

pub const emsc = Source(
  id: "emsc",
  name: "EMSC",
  homepage: option.Some("https://www.seismicportal.eu/"),
  license: "CC-BY-4.0",
  attribution_text: "Credit: EMSC/CSEM, https://www.emsc-csem.org",
  redistributable: True,
  priority: 90,
)

pub const all: List(Source) = [noaa, usgs, emsc]

pub fn lookup(id: String) -> Result(Source, Nil) {
  list.find(all, fn(source) { source.id == id })
}

pub fn to_json(source: Source) -> json.Json {
  json.object([
    #("id", json.string(source.id)),
    #("name", json.string(source.name)),
    #("homepage", json.nullable(source.homepage, json.string)),
    #("license", json.string(source.license)),
    #("attribution_text", json.string(source.attribution_text)),
    #("redistributable", json.bool(source.redistributable)),
    #("priority", json.int(source.priority)),
  ])
}

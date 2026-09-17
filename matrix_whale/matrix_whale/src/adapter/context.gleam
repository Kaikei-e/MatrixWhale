import adapter/alert_hub.{type HubMsg}
import adapter/earthquake_hub.{type EarthquakeHubMsg}
import gleam/erlang/process.{type Subject}
import intake/seen_set.{type SeenSet}
import pog.{type Connection}

pub type Context {
  Context(
    secret: String,
    db: Connection,
    hub: Subject(HubMsg),
    earthquake_hub: Subject(EarthquakeHubMsg),
    seen: SeenSet,
  )
}

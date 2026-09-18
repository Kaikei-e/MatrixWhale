import adapter/alert_hub.{type HubMsg}
import adapter/earthquake_hub.{type EarthquakeHubMsg}
import adapter/hazard_hub.{type HazardHubMsg}
import gleam/erlang/process.{type Subject}
import intake/seen_set.{type SeenSet}
import pog.{type Connection}

pub type Context {
  Context(
    secret: String,
    db: Connection,
    hub: Subject(HubMsg),
    earthquake_hub: Subject(EarthquakeHubMsg),
    hazard_hub: Subject(HazardHubMsg),
    seen: SeenSet,
  )
}

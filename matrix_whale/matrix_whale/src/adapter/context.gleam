import adapter/alert_hub.{type HubMsg}
import gleam/erlang/process.{type Subject}
import pog.{type Connection}

pub type Context {
  Context(secret: String, db: Connection, hub: Subject(HubMsg))
}

import gleam/pgo.{type Connection}

pub type Context {
  Context(secret: String, db: Connection)
}

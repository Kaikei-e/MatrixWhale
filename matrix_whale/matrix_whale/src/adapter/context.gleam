import pog.{type Connection}

pub type Context {
  Context(secret: String, db: Connection)
}

import dot_env as dot
import dot_env/env
import gleam/erlang/process
import gleam/int
import gleam/string
import pog
import wisp

pub fn initialize_db() -> pog.Connection {
  dot.load_default()

  let db_host = case env.get_string("POSTGRES_HOST") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_HOST not set")
      panic
    }
  }

  let db_port = case env.get_int("POSTGRES_PORT") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_PORT not set")
      panic
    }
  }

  let db_user = case env.get_string("POSTGRES_USER") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_USER not set")
      panic
    }
  }

  let db_password = case env.get_string("POSTGRES_PASSWORD") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_PASSWORD not set")
      panic
    }
  }

  let db_name = case env.get_string("POSTGRES_DB") {
    Ok(value) -> value
    Error(_) -> {
      wisp.log_error("POSTGRES_DB not set")
      panic
    }
  }

  let database_url =
    "postgres://"
    <> db_user
    <> ":"
    <> db_password
    <> "@"
    <> db_host
    <> ":"
    <> int.to_string(db_port)
    <> "/"
    <> db_name

  let pool_name = process.new_name("matrix_whale_db")
  let conf = pog.url_config(pool_name, database_url)
  let _config = case conf {
    Ok(config) -> config
    Error(err) -> {
      wisp.log_error("Error creating database config: " <> string.inspect(err))
      panic
    }
  }

  pog.named_connection(pool_name)
}

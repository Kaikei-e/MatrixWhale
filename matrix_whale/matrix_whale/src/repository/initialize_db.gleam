import dot_env as dot
import dot_env/env
import gleam/option.{Some}
import gleam/pgo.{type Connection}

pub fn initialize_db() -> Connection {
  dot.new()
  |> dot.set_path(".env")
  |> dot.set_debug(False)
  |> dot.load

  let db_host = case env.get_string("POSTGRES_HOST") {
    Ok(value) -> value
    Error(_) -> panic
  }

  let db_port = case env.get_int("POSTGRES_PORT") {
    Ok(value) -> value
    Error(_) -> panic
  }

  let db_user = case env.get_string("POSTGRES_USER") {
    Ok(value) -> value
    Error(_) -> panic
  }

  let db_password = case env.get_string("POSTGRES_PASSWORD") {
    Ok(value) -> value
    Error(_) -> panic
  }

  let db_name = case env.get_string("POSTGRES_DB") {
    Ok(value) -> value
    Error(_) -> panic
  }

  pgo.connect(
    pgo.Config(
      ..pgo.default_config(),
      host: db_host,
      port: db_port,
      password: Some(db_password),
      database: db_name,
      pool_size: 15,
      user: db_user,
    ),
  )
}

// Manual read-only benchmark; not part of the mutating integration suite.
import domain/event
import dot_env/env
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import pog
import repository/event_writer

type TimeUnit {
  Microsecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

@external(erlang, "review_hydration_ffi", "read_only_snapshot")
fn read_only_snapshot(
  pool: process.Name(pog.Message),
  run: fn(pog.Connection) -> a,
) -> a

pub fn main() {
  let assert Ok(url) = env.get_string("MATRIXWHALE_REVIEW_DATABASE_URL")
  let pool = process.new_name("review_hydration")
  let assert Ok(config) = pog.url_config(pool, url)
  let assert Ok(_) = pog.start(pog.pool_size(config, 1))
  // Allow the single connection to start before checking out a transaction.
  process.sleep(500)
  let results =
    read_only_snapshot(pool, fn(tx) {
      let assert Ok(_) =
        pog.query("SET LOCAL statement_timeout = '10s'")
        |> pog.returning(decode.success(Nil))
        |> pog.execute(tx)
      [
        scenario(
          "24h_default",
          "occurred_at >= now() - interval '24 hours' AND magnitude >= 2.5 AND event_type = 'earthquake'",
          tx,
        ),
        scenario(
          "168h_all_magnitudes_all_types",
          "occurred_at >= now() - interval '168 hours'",
          tx,
        ),
      ]
    })
  io.println(
    json.to_string(
      json.object([
        #("transaction", json.string("repeatable read, read only")),
        #(
          "scope",
          json.string(
            "hydration only; fixed event selection outside timing; no HTTP serialization",
          ),
        ),
        #("results", json.array(results, fn(x) { x })),
      ]),
    ),
  )
}

fn scenario(
  name: String,
  predicate: String,
  conn: pog.Connection,
) -> json.Json {
  let assert Ok(rows) =
    pog.query(
      "SELECT "
      <> event.columns
      <> " FROM sea.event WHERE status IS DISTINCT FROM 'deleted' AND "
      <> predicate
      <> " ORDER BY occurred_at DESC,id",
    )
    |> pog.returning(event.row_decoder())
    |> pog.execute(conn)
  // Warm both paths before alternating the measurement order.
  let assert Ok(warm_legacy) = legacy(rows.rows, conn)
  let assert Ok(warm_batch) = event_writer.to_views(rows.rows, conn)
  let samples =
    list.map([1, 2, 3, 4, 5], fn(i) {
      let #(old_us, old, new_us, new) = case i % 2 {
        0 -> {
          let #(new_us, new) =
            measure(fn() { event_writer.to_views(rows.rows, conn) })
          let #(old_us, old) = measure(fn() { legacy(rows.rows, conn) })
          #(old_us, old, new_us, new)
        }
        _ -> {
          let #(old_us, old) = measure(fn() { legacy(rows.rows, conn) })
          let #(new_us, new) =
            measure(fn() { event_writer.to_views(rows.rows, conn) })
          #(old_us, old, new_us, new)
        }
      }
      process.sleep(100)
      json.object([
        #("iteration", json.int(i)),
        #("legacy_us", json.int(old_us)),
        #("batch_us", json.int(new_us)),
        #("exact_equal", json.bool(old == new)),
      ])
    })
  let member_count =
    list.fold(warm_legacy, 0, fn(n, view) { n + list.length(view.members) })
  json.object([
    #("name", json.string(name)),
    #("events", json.int(list.length(rows.rows))),
    #("members", json.int(member_count)),
    #("warm_exact_equal", json.bool(warm_legacy == warm_batch)),
    #(
      "legacy_hydration_sql_calls_code_derived",
      json.int(list.length(rows.rows) + member_count),
    ),
    #("batch_hydration_sql_calls_code_derived", json.int(2)),
    #("samples", json.array(samples, fn(x) { x })),
  ])
}

fn legacy(rows: List(event.Event), conn: pog.Connection) {
  list.try_map(rows, fn(row) { event_writer.to_view(row, conn) })
}

fn measure(run: fn() -> Result(a, String)) -> #(Int, a) {
  let started = monotonic_time(Microsecond)
  let assert Ok(value) = run()
  #(monotonic_time(Microsecond) - started, value)
}

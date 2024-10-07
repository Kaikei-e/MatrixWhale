import birl
import gleam/list
import gleam/option.{None, Some}
import gleam/pgo
import gleam/result
import gleam/string
import message/reviever/models/noaa.{type FeatureElement}
import wisp

pub fn write_noaa_alerts(
  features: List(FeatureElement),
  conn: pgo.Connection,
) -> Result(Nil, String) {
  let insert_alert = fn(feature: FeatureElement) -> Result(Nil, String) {
    let severity = feature.properties.severity

    let datetime = case feature.properties.sent {
      Some(sent) -> birl.parse(sent)
      None -> birl.parse(feature.properties.effective)
    }

    let datetime_parsed = case datetime {
      Ok(datetime) -> datetime
      Error(_) -> birl.now()
    }

    let timestamp = birl.to_iso8601(datetime_parsed)

    case
      pgo.execute(
        "INSERT INTO sea.severity (severity, datetime) VALUES ($1, $2) ON CONFLICT (severity, datetime) DO NOTHING;",
        conn,
        [pgo.text(string.inspect(severity)), pgo.text(timestamp)],
        fn(_) { Ok(Nil) },
      )
    {
      Ok(_) -> Ok(Nil)
      Error(err) -> {
        let error_message = err
        wisp.log_error(
          "Failed to insert severity: " <> string.inspect(error_message),
        )
        Error(string.inspect(error_message))
      }
    }
  }

  pgo.transaction(conn, fn(_) {
    features
    |> list.try_map(fn(feature) { insert_alert(feature) })
  })
  |> result.map_error(fn(err) {
    case err {
      pgo.TransactionRolledBack(reason) -> reason
      // pgo.TransactionQueryError(pgo.PostgresqlError(
      //   "40000",
      //   "transaction_rollback",
      //   string.inspect(reason),
      // ))
      pgo.TransactionQueryError(query_error) -> string.inspect(query_error)
      // pgo.TransactionQueryError(pgo.PostgresqlError(
      //   "25P02",
      //   "in_failed_sql_transaction",
      //   string.inspect(query_error),
      // ))
    }
  })
  |> result.map(fn(_) { Nil })
}

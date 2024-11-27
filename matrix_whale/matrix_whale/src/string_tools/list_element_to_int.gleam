import gleam/int
import gleam/result
import gleam/yielder

pub fn list_element_to_int(list: List(String), index: Int) -> Result(Int, Nil) {
  let parsed =
    yielder.from_list(list)
    |> yielder.at(index)
    |> result.map(fn(s) { int.parse(s) })
    |> result.map(fn(e) {
      case e {
        Ok(i) -> i
        Error(_) -> 0
      }
    })

  case parsed {
    Ok(i) -> Ok(i)
    Error(_) -> Error(Nil)
  }
}

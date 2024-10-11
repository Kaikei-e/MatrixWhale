import gleam/int
import gleam/iterator
import gleam/result

pub fn list_element_to_int(list: List(String), index: Int) -> Result(Int, Nil) {
  let parsed =
    iterator.from_list(list)
    |> iterator.at(index)
    |> result.map(fn(s) { int.parse(s) })
    |> result.map(fn(e) {
      case e {
        Ok(i) -> i
        Error(e) -> 0
      }
    })

  case parsed {
    Ok(i) -> Ok(i)
    Error(_) -> Error(Nil)
  }
}

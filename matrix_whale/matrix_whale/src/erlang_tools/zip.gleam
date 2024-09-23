@external(erlang, "zlib", "gunzip")
fn raw_gunzip(data: BitArray) -> String

pub fn gunzip(data: BitArray) -> Result(String, Nil) {
  let bytes = raw_gunzip(data)
  Ok(bytes)
}

import gleam/string

pub fn replace_double_backslash(input: String, replacement: String) -> String {
  string.replace(input, "\\\\", replacement)
}

pub fn replace_back_slash(input: String) -> String {
  string.replace(input, "\n", "")
}

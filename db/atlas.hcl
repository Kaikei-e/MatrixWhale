env "local" {
  src = "file://schema.sql"
  # Extensions are Atlas Pro-only (require `atlas login`), so pg_trgm is
  # created as plain SQL in migrations/..._init.sql instead of here.
  dev = "docker://postgres/16/dev"
  url = getenv("MATRIX_WHALE_DATABASE_URL")

  # Full-database scope (not schema-scoped via ?search_path=sea): a schema-scoped
  # URL requires the "sea" schema to already exist on both `url` and the ephemeral
  # `dev` container, which Atlas cannot bootstrap itself. "public" must stay listed
  # here too, or a live target's pre-existing public schema gets diffed as a drop.
  schemas = ["public", "sea"]

  migration {
    dir = "file://migrations"
  }
}

#!/usr/bin/env python3
"""Run the manual Gleam read-only benchmark without printing DB credentials."""
import json
import datetime as dt
import hashlib
import os
from pathlib import Path
import subprocess
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "matrix_whale/matrix_whale"


def main():
    started = dt.datetime.now(dt.timezone.utc).isoformat()
    source_paths = [
        PROJECT / "src/repository/event_writer.gleam",
        PROJECT / "src/repository/earthquake_reader.gleam",
        PROJECT / "test/review_hydration_benchmark.gleam",
        PROJECT / "test/review_hydration_ffi.erl",
    ]
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in source_paths}
    values = {}
    for line in (ROOT / ".env").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    url = "postgres://{}:{}@127.0.0.1:5440/{}?sslmode=disable".format(
        quote(values["POSTGRES_USER"], safe=""),
        quote(values["POSTGRES_PASSWORD"], safe=""),
        quote(values["POSTGRES_DB"], safe=""),
    )
    task_env = os.environ.copy()
    task_env["MATRIXWHALE_REVIEW_DATABASE_URL"] = url
    result = subprocess.run(
        ["gleam", "run", "-m", "review_hydration_benchmark"],
        cwd=PROJECT, env=task_env, capture_output=True, text=True, timeout=180,
    )
    # Suppress arbitrary tool output to avoid accidentally disclosing a URL.
    if result.returncode:
        diagnostic = (result.stdout + result.stderr).replace(url, "[database URL redacted]")
        diagnostic = diagnostic.replace(values["POSTGRES_PASSWORD"], "[password redacted]")
        (ROOT / "docs/reviews/evidence/db/hydration-benchmark-error.txt").write_text(diagnostic)
        raise SystemExit("Benchmark failed; sanitized diagnostic saved.")
    lines = [line for line in result.stdout.splitlines() if line.startswith('{"transaction"')]
    if len(lines) != 1:
        raise SystemExit("Benchmark did not return the expected JSON record.")
    data = json.loads(lines[0])
    data.update(started_at_utc=started,
                finished_at_utc=dt.datetime.now(dt.timezone.utc).isoformat(),
                source_sha256=source_hashes,
                benchmark_checkout_timeout_seconds=120,
                database_statement_timeout_seconds=10)
    if any(hashlib.sha256(p.read_bytes()).hexdigest() != source_hashes[str(p.relative_to(ROOT))]
           for p in source_paths):
        raise SystemExit("Benchmark source changed during execution; comparison not saved.")
    if not all(r["warm_exact_equal"] and all(s["exact_equal"] for s in r["samples"])
               for r in data["results"]):
        raise SystemExit("Legacy and batch results differ; comparison not accepted.")
    target = ROOT / "docs/reviews/evidence/db/hydration-benchmark.json"
    target.write_text(json.dumps(data, indent=2) + "\n")
    print(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()

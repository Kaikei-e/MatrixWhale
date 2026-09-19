#!/usr/bin/env python3
"""Bounded, read-only MatrixWhale HTTP/resource sampling (not a capacity test)."""
import argparse
import datetime as dt
import hashlib
import json
import math
import pathlib
import statistics
import subprocess
import time
import urllib.error
import urllib.request


PATHS = [
    "/api/v1/alerts/active",
    "/api/v1/earthquakes/recent?hours=24",
    "/api/v1/earthquakes/recent?hours=168&minmag=all&type=all",
    "/api/v1/hazards/recent",
    "/api/v1/timeline?limit=50",
    "/api/v1/cap/feeds",
    "/api/v1/sources",
]
CONTAINERS = ["matrixwhale-" + name + "-1" for name in [
    "db", "matrix_whale", "cap_adapter", "noaa_adapter", "usgs_adapter",
    "emsc_adapter", "gdacs_adapter", "web", "proxy",
    "federation_orchestrator", "rss_feed_adapter",
]]


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=15)
    return {"command": args, "exit_code": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}


def snapshot():
    return {"at": utc(), "docker": command([
        "docker", "stats", "--no-stream", "--format", "{{json .}}", *CONTAINERS]),
        "memory": pathlib.Path("/proc/meminfo").read_text(),
        "load": pathlib.Path("/proc/loadavg").read_text(),
        "pressure": {key: pathlib.Path("/proc/pressure/" + key).read_text()
                     for key in ["cpu", "io", "memory"]},
        "vmstat": {line.split()[0]: int(line.split()[1]) for line in
                   pathlib.Path("/proc/vmstat").read_text().splitlines()
                   if line.split()[0] in ["pswpin", "pswpout", "pgmajfault"]}}


def fetch(base, path, etag=None):
    headers = {"User-Agent": "MatrixWhale-readonly-review/1.0"}
    if etag:
        headers["If-None-Match"] = etag
    start = time.perf_counter()
    row = {"at": utc(), "base": base, "path": path, "conditional": bool(etag)}
    payload = None
    try:
        try:
            response = urllib.request.urlopen(
                urllib.request.Request(base + path, headers=headers), timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            row["ttfb_ms"] = (time.perf_counter() - start) * 1000
            body = response.read(32 * 1024 * 1024 + 1)
            row.update(status=response.code, bytes=len(body),
                       etag=response.headers.get("ETag"),
                       content_encoding=response.headers.get("Content-Encoding"),
                       cache_control=response.headers.get("Cache-Control"),
                       sha256=hashlib.sha256(body).hexdigest())
            if len(body) > 32 * 1024 * 1024:
                row["error"] = "response exceeded 32 MiB bound"
            else:
                try:
                    payload = json.loads(body)
                    if isinstance(payload, list):
                        row["items"] = len(payload)
                    elif isinstance(payload, dict):
                        row["array_counts"] = {key: len(value) for key, value in
                                               payload.items() if isinstance(value, list)}
                        row["keys"] = list(payload)
                except (ValueError, UnicodeDecodeError):
                    pass
    except (OSError, TimeoutError) as error:
        row["error"] = str(error)
    row["elapsed_ms"] = (time.perf_counter() - start) * 1000
    return row, payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--interval", type=float, default=0.25)
    args = parser.parse_args()
    if not 1 <= args.samples <= 30 or args.interval < 0.25:
        parser.error("samples must be 1..30 and interval >=0.25 seconds")
    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    result = {"started": utc(), "method": {
        "description": "sequential loopback GETs; new connection per request; no saturation test",
        "samples_per_route": args.samples, "minimum_gap_seconds": args.interval,
        "percentile": "nearest rank; small sample, descriptive only",
        "payloads_saved": False}, "resources": [snapshot()], "requests": [], "pipeline": []}
    for base in ["http://127.0.0.1:8081", "http://127.0.0.1:8180"]:
        row, payload = fetch(base, "/api/v1/pipeline/status")
        result["pipeline"].append({"request": row, "status": payload})
        time.sleep(args.interval)
        for path in PATHS:
            last_etag = None
            for _ in range(args.samples):
                row, _ = fetch(base, path)
                result["requests"].append(row)
                last_etag = row.get("etag")
                time.sleep(args.interval)
                if row.get("error") or row.get("status", 500) >= 500:
                    break
            if last_etag:
                for _ in range(3):
                    row, _ = fetch(base, path, last_etag)
                    result["requests"].append(row)
                    time.sleep(args.interval)
        result["resources"].append(snapshot())
        out.write_text(json.dumps(result, indent=2) + "\n")
    row, payload = fetch("http://127.0.0.1:8081", "/api/v1/pipeline/status")
    result["pipeline"].append({"request": row, "status": payload})
    summary = []
    for base in ["http://127.0.0.1:8081", "http://127.0.0.1:8180"]:
        for path in PATHS:
            for conditional in [False, True]:
                rows = [r for r in result["requests"] if r["base"] == base
                        and r["path"] == path and r["conditional"] == conditional]
                if not rows:
                    continue
                times = sorted(r["elapsed_ms"] for r in rows)
                summary.append({"base": base, "path": path, "conditional": conditional,
                                "n": len(rows), "statuses": [r.get("status") for r in rows],
                                "median_ms": statistics.median(times),
                                "p95_ms": times[math.ceil(len(times) * 0.95) - 1],
                                "min_bytes": min(r.get("bytes", 0) for r in rows),
                                "max_bytes": max(r.get("bytes", 0) for r in rows)})
    result.update(finished=utc(), summary=summary)
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

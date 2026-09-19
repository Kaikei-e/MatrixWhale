#!/usr/bin/env python3
"""Count public object metadata only; never download satellite/forecast payloads."""
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import statistics
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--date", required=True, help="Completed UTC date, YYYY-MM-DD")
    parser.add_argument("--output", required=True)
    parser.add_argument("--cached-dir", help="Read previously collected XML listings")
    args = parser.parse_args()
    day = dt.date.fromisoformat(args.date)
    jobs = []
    for product, short in [("GLM-L2-LCFA", "glm"), ("ABI-L1b-RadF", "abi")]:
        for hour in ["00", "12"]:
            prefix = f"{product}/{day:%Y}/{day:%j}/{hour}/"
            filename = f"matrixwhale-goes19-{short}" + ("" if hour == "00" else "-12") + "-list.xml"
            jobs.append(("noaa-goes19.s3.amazonaws.com", prefix, filename, "hour"))
    for hour in ["00", "06", "12", "18"]:
        prefix = f"{day:%Y%m%d}/{hour}z/ifs/0p25/oper/"
        filename = "matrixwhale-ecmwf-oper" + ("" if hour == "00" else "-" + hour) + "-list.xml"
        jobs.append(("ecmwf-forecasts.s3.eu-central-1.amazonaws.com", prefix, filename, "cycle"))
    ns = {"s": "http://s3.amazonaws.com/doc/2006-03-01/"}
    result = {"recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(),
              "data_date_utc": str(day), "method": "S3 ListObjectsV2 metadata, max-keys=1000; no payload GET",
              "collection": "cached XML (mtime retained below)" if args.cached_dir else "live HTTPS", "samples": []}
    for host, prefix, filename, unit in jobs:
        url = "https://" + host + "/?" + urllib.parse.urlencode(
            {"list-type": "2", "prefix": prefix, "max-keys": "1000"})
        if args.cached_dir:
            cached = pathlib.Path(args.cached_dir) / filename
            raw = cached.read_bytes()
            observed = dt.datetime.fromtimestamp(cached.stat().st_mtime, dt.timezone.utc).isoformat()
        else:
            with urllib.request.urlopen(url, timeout=20) as response:
                raw = response.read(2 * 1024 * 1024)
            observed = dt.datetime.now(dt.timezone.utc).isoformat()
        root = ET.fromstring(raw)
        if root.findtext("s:IsTruncated", namespaces=ns) != "false":
            raise RuntimeError("Incomplete listing; paginate before interpreting: " + url)
        if root.findtext("s:Prefix", namespaces=ns) != prefix:
            raise RuntimeError("Cached prefix differs from requested date: " + url)
        objects = [{"key": item.findtext("s:Key", namespaces=ns),
                    "size": int(item.findtext("s:Size", namespaces=ns)),
                    "last_modified": item.findtext("s:LastModified", namespaces=ns)}
                   for item in root.findall("s:Contents", ns)]
        sizes = [item["size"] for item in objects]
        total = sum(sizes)
        sample = {"url": url, "observed_at": observed, "prefix": prefix, "unit": unit,
                  "listing_sha256": hashlib.sha256(raw).hexdigest(), "listing_bytes": len(raw),
                  "truncated": False, "objects": objects, "count": len(objects), "bytes": total,
                  "median_object_bytes": statistics.median(sizes) if sizes else None,
                  "max_object_bytes": max(sizes) if sizes else None}
        if unit == "hour":
            sample["extrapolated_bytes_24h_NOT_measured"] = total * 24
        result["samples"].append(sample)
    cycles = [sample for sample in result["samples"] if sample["unit"] == "cycle"]
    result["ifs_oper_measured_day_bytes_including_indexes"] = sum(sample["bytes"] for sample in cycles)
    result["ifs_oper_measured_day_grib2_bytes"] = sum(
        obj["size"] for sample in cycles for obj in sample["objects"] if obj["key"].endswith(".grib2"))
    result["limitations"] = [
        "S3 advertised object size; no decoding, transfer-throughput or memory benchmark.",
        "Two GOES hours are samples, not daily/seasonal measurements; 24x is arithmetic extrapolation.",
        "IFS sample only oper/0p25, not ensembles, waves, AIFS or the full ECMWF catalog."]
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    for sample in result["samples"]:
        print(sample["prefix"], sample["count"], sample["bytes"])
    print("IFS oper measured day bytes", result["ifs_oper_measured_day_bytes_including_indexes"])


if __name__ == "__main__":
    main()

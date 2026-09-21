#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "pyshp>=2.3.1",
# ]
# ///

"""
JMA Forecast Area GIS Data Loader

Prepares and loads JMA (Japan Meteorological Agency) municipality-level weather
alert forecast areas (市町村等（気象警報等）) into the `sea.jma_area` table.

Usage:
    # 1. Pipe SQL directly to the container (recommended):
    uv run db/scripts/load_jma_areas.py https://www.data.jma.go.jp/developer/gis/20260226_AreaInformationCity_weather_GIS.zip | docker compose exec -T db psql -U user1 -d sea

    # 2. From a locally downloaded zip file:
    uv run db/scripts/load_jma_areas.py /path/to/20260226_AreaInformationCity_weather_GIS.zip | docker compose exec -T db psql -U user1 -d sea

    # 3. Save to a SQL file:
    uv run db/scripts/load_jma_areas.py 20260226_AreaInformationCity_weather_GIS.zip -o jma_areas.sql

    # 4. Direct load into database (requires psycopg/psycopg2 driver or host psql client):
    uv run db/scripts/load_jma_areas.py 20260226_AreaInformationCity_weather_GIS.zip --db-url "$DATABASE_URL"

Options:
    --tolerance   Simplification tolerance for ST_SimplifyPreserveTopology in degrees
                  (default: 0.001, approx. 100 meters).
    --batch-size  Number of rows per INSERT batch (default: 100).
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

import shapefile


def log(msg: str) -> None:
    sys.stderr.write(f"[load_jma_areas] {msg}\n")
    sys.stderr.flush()


def download_url(url: str, dest_path: str) -> None:
    log(f"Downloading from {url}...")
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "MatrixWhale-GIS-Loader/1.0"},
    )
    with urllib.request.urlopen(req, timeout=60) as response, open(dest_path, "wb") as out_file:
        total_size = response.getheader("Content-Length")
        total_bytes = int(total_size) if total_size else None
        downloaded = 0
        chunk_size = 64 * 1024
        while True:
            chunk = response.read(chunk_size)
            if not chunk:
                break
            out_file.write(chunk)
            downloaded += len(chunk)
            if total_bytes:
                percent = (downloaded / total_bytes) * 100
                if sys.stderr.isatty():
                    sys.stderr.write(f"\r[load_jma_areas] Downloaded {downloaded // (1024*1024)}MB / {total_bytes // (1024*1024)}MB ({percent:.1f}%)")
                    sys.stderr.flush()
    if sys.stderr.isatty():
        sys.stderr.write("\n")
    log("Download complete.")


def safe_extract_zip(zip_path: str, extract_dir: str) -> str:
    log(f"Extracting {zip_path}...")
    target_dir = os.path.abspath(extract_dir)
    with zipfile.ZipFile(zip_path, "r") as zf:
        for member in zf.infolist():
            resolved = os.path.abspath(os.path.join(target_dir, member.filename))
            if not resolved.startswith(target_dir + os.sep) and resolved != target_dir:
                raise ValueError(f"Zip slip security error: {member.filename}")
            ext = os.path.splitext(member.filename)[1].lower()
            if ext in (".shp", ".shx", ".dbf", ".prj", ".cpg"):
                zf.extract(member, target_dir)

    for root, _, files in os.walk(target_dir):
        for f in files:
            if f.lower().endswith(".shp"):
                return os.path.join(root, f)

    raise FileNotFoundError("No .shp shapefile found inside zip archive")


def ring_to_wkt(ring: list) -> str:
    coords = ", ".join(f"{pt[0]:.7f} {pt[1]:.7f}" for pt in ring)
    return f"({coords})"


def polygon_to_wkt(rings: list) -> str:
    ring_wkts = ", ".join(ring_to_wkt(r) for r in rings)
    return f"({ring_wkts})"


def extract_polygons(geo: dict) -> list:
    geom_type = geo.get("type")
    coords = geo.get("coordinates", [])
    if geom_type == "Polygon":
        return [coords]
    elif geom_type == "MultiPolygon":
        return coords
    else:
        return []


def escape_sql_str(val: str) -> str:
    return val.replace("'", "''")


def find_field(field_names: list, candidates: list) -> str:
    for c in candidates:
        if c in field_names:
            return c
    return None


def read_shapefile_areas(shp_path: str) -> dict:
    log(f"Reading shapefile from {shp_path}...")

    encodings = []
    cpg_path = os.path.splitext(shp_path)[0] + ".cpg"
    if os.path.exists(cpg_path):
        try:
            with open(cpg_path, "r", encoding="ascii", errors="ignore") as f:
                cpg_enc = f.read().strip()
                if cpg_enc:
                    if cpg_enc.lower() == "system":
                        encodings.append("cp932")
                    else:
                        encodings.append(cpg_enc)
        except Exception as e:
            log(f"Failed to read .cpg file: {e}")

    # UTF-8 is first in the fallback list, as JMA datasets use it.
    encodings.extend(["utf-8", "cp932", "shift_jis"])

    # Remove duplicates preserving order
    seen = set()
    encodings = [x for x in encodings if not (x.lower() in seen or seen.add(x.lower()))]

    sf = None
    for enc in encodings:
        try:
            reader = shapefile.Reader(shp_path, encoding=enc)
            # A single record might happen to decode under the wrong encoding
            # (e.g. if it contains only ASCII). To be robust, we read all DBF
            # records to ensure the encoding is valid for the entire file.
            for _ in reader.iterRecords():
                pass

            sf = shapefile.Reader(shp_path, encoding=enc)
            log(f"Opened shapefile with encoding '{enc}'")
            break
        except (UnicodeDecodeError, shapefile.ShapefileException):
            # pyshp can raise shapefile.dbfFileException on decode failures,
            # not just UnicodeDecodeError. Catch only decode-related exceptions.
            continue

    if sf is None:
        raise ValueError(f"Failed to open shapefile {shp_path} with encodings: {encodings}")

    fields = [f[0].lower() for f in sf.fields if f[0] != "DeletionFlag"]
    log(f"Found fields: {fields}")

    code_candidates = ["code", "citycode", "regioncode", "areacode", "city_code", "area_code", "jma_code"]
    name_candidates = ["name", "cityname", "regionname", "areaname", "city_name", "area_name", "name_kanji"]

    code_field = find_field(fields, code_candidates)
    name_field = find_field(fields, name_candidates)

    if not code_field:
        raise ValueError(f"Could not locate code field among shapefile fields: {fields}")
    if not name_field:
        raise ValueError(f"Could not locate name field among shapefile fields: {fields}")

    log(f"Using attribute mapping: code='{code_field}', name='{name_field}'")

    areas = {}
    for i in range(len(sf)):
        record_dict = sf.record(i).as_dict()
        record_lower = {k.lower(): v for k, v in record_dict.items()}
        code = str(record_lower.get(code_field, "")).strip()
        name = str(record_lower.get(name_field, "")).strip()

        if not code:
            continue

        shape = sf.shape(i)
        geo = shape.__geo_interface__
        polys = extract_polygons(geo)
        if not polys:
            continue

        if code not in areas:
            areas[code] = {"name": name, "polygons": []}
        areas[code]["polygons"].extend(polys)

    log(f"Loaded {len(areas)} unique forecast areas")
    return areas


def generate_sql_statements(areas: dict, tolerance: float, batch_size: int = 100):
    yield "BEGIN;\n"

    items = list(areas.items())
    for i in range(0, len(items), batch_size):
        chunk = items[i : i + batch_size]
        values = []
        for code, data in chunk:
            name = escape_sql_str(data["name"])
            poly_wkts = ", ".join(polygon_to_wkt(poly) for poly in data["polygons"])
            wkt = f"MULTIPOLYGON ({poly_wkts})"

            if tolerance > 0:
                geom_expr = (
                    f"ST_Multi(ST_SimplifyPreserveTopology(ST_GeomFromText('{wkt}', 4326), {tolerance}))"
                )
            else:
                geom_expr = f"ST_Multi(ST_GeomFromText('{wkt}', 4326))"

            values.append(f"  ('{code}', '{name}', {geom_expr})")

        values_sql = ",\n".join(values)
        stmt = (
            "INSERT INTO sea.jma_area (code, name, geom)\n"
            "VALUES\n"
            f"{values_sql}\n"
            "ON CONFLICT (code) DO UPDATE SET\n"
            "  name = EXCLUDED.name,\n"
            "  geom = EXCLUDED.geom;\n\n"
        )
        yield stmt

    yield "COMMIT;\n"


def execute_sql(sql_generator, db_url: str) -> None:
    log("Executing SQL into database...")
    try:
        import psycopg
        log("Using psycopg to load data")
        with psycopg.connect(db_url) as conn:
            with conn.cursor() as cur:
                for stmt in sql_generator:
                    cur.execute(stmt)
            conn.commit()
        log("Data load successful via psycopg.")
        return
    except ImportError:
        pass

    try:
        import psycopg2
        log("Using psycopg2 to load data")
        with psycopg2.connect(db_url) as conn:
            with conn.cursor() as cur:
                for stmt in sql_generator:
                    cur.execute(stmt)
            conn.commit()
        log("Data load successful via psycopg2.")
        return
    except ImportError:
        pass

    log("Neither psycopg nor psycopg2 found; piping to psql subprocess")
    proc = subprocess.Popen(
        ["psql", db_url],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    for stmt in sql_generator:
        proc.stdin.write(stmt)
    stdout, stderr = proc.communicate()
    if proc.returncode != 0:
        log(f"psql failed with code {proc.returncode}:\n{stderr}")
        sys.exit(proc.returncode)
    log("Data load successful via psql.")


def main():
    parser = argparse.ArgumentParser(
        description="Load JMA forecast area shapefile data into sea.jma_area."
    )
    parser.add_argument(
        "source",
        help="Path or URL to AreaInformationCity_weather_GIS.zip (or extracted .shp file)",
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Output SQL file (default: stdout)",
    )
    parser.add_argument(
        "--db-url",
        help="Optional PostgreSQL database URL to execute into directly",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=0.001,
        help="Simplification tolerance for ST_SimplifyPreserveTopology in degrees (default: 0.001)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=100,
        help="Number of areas per INSERT batch (default: 100)",
    )

    args = parser.parse_args()

    temp_dir = tempfile.mkdtemp(prefix="jma_gis_")
    try:
        source_arg = args.source
        if source_arg.startswith("http://") or source_arg.startswith("https://"):
            zip_dest = os.path.join(temp_dir, "jma_gis.zip")
            download_url(source_arg, zip_dest)
            shp_path = safe_extract_zip(zip_dest, temp_dir)
        elif zipfile.is_zipfile(source_arg):
            shp_path = safe_extract_zip(source_arg, temp_dir)
        elif source_arg.lower().endswith(".shp") and os.path.exists(source_arg):
            shp_path = source_arg
        else:
            raise FileNotFoundError(f"Source file not found or invalid format: {source_arg}")

        areas = read_shapefile_areas(shp_path)

        if args.db_url:
            execute_sql(generate_sql_statements(areas, args.tolerance, args.batch_size), args.db_url)
        elif args.output:
            log(f"Writing SQL to {args.output}...")
            with open(args.output, "w", encoding="utf-8") as out:
                for stmt in generate_sql_statements(areas, args.tolerance, args.batch_size):
                    out.write(stmt)
            log("SQL generation complete.")
        else:
            for stmt in generate_sql_statements(areas, args.tolerance, args.batch_size):
                sys.stdout.write(stmt)
            sys.stdout.flush()

    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()

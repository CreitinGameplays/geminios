#!/usr/bin/env python3
import argparse
import gzip
import os
import sys
import urllib.request


def read_simple_kv_config(path):
    config = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()
    except OSError:
        pass
    return config


def download(url, dest_path):
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    tmp_path = dest_path + ".part"
    request = urllib.request.Request(url, headers={"User-Agent": "GeminiOS fetch_debian_binary"})
    with urllib.request.urlopen(request) as response, open(tmp_path, "wb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            output.write(chunk)
    os.replace(tmp_path, dest_path)


def parse_package_index(index_path, package_name, architecture):
    preferred = None
    fallback = None
    fields = {}

    def consider(record):
        nonlocal preferred, fallback
        if record.get("Package") != package_name:
            return
        record_arch = record.get("Architecture", "")
        if architecture != "all" and record_arch == architecture:
            if preferred is None:
                preferred = record
        elif record_arch == "all":
            if fallback is None:
                fallback = record

    with gzip.open(index_path, "rt", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.rstrip("\n")
            if not line:
                if fields:
                    consider(fields)
                fields = {}
                continue
            if line[0].isspace():
                continue
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            fields[key] = value.strip()
        if fields:
            consider(fields)

    return preferred or fallback


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--config", default=os.path.join(os.path.dirname(__file__), "gpkg_debian.conf"))
    args = parser.parse_args()

    config = read_simple_kv_config(args.config)
    packages_url = config.get(
        "PACKAGES_URL",
        "https://deb.debian.org/debian/dists/testing/main/binary-amd64/Packages.gz",
    )
    base_url = config.get("BASE_URL", "https://deb.debian.org/debian").rstrip("/")

    cache_dir = os.path.abspath(args.cache_dir)
    os.makedirs(cache_dir, exist_ok=True)
    packages_path = os.path.join(cache_dir, os.path.basename(packages_url))
    if not os.path.exists(packages_path):
        download(packages_url, packages_path)

    record = parse_package_index(packages_path, args.package, args.arch)
    if record is None:
        print(f"failed to resolve Debian package {args.package} for architecture {args.arch}", file=sys.stderr)
        return 1

    filename = record.get("Filename", "")
    version = record.get("Version", "")
    if not filename or not version:
        print(f"incomplete package metadata for {args.package}", file=sys.stderr)
        return 1

    deb_url = base_url + "/" + filename.lstrip("/")
    deb_path = os.path.join(cache_dir, os.path.basename(filename))
    if not os.path.exists(deb_path):
        download(deb_url, deb_path)

    sys.stdout.write(version + "\t" + deb_path + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

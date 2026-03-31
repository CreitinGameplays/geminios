#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
GPKG_DIR = ROOT_DIR / "gpkg"
SYS_INFO_PATH = ROOT_DIR / "src" / "sys_info.h"
DEFAULT_EXPORT_ROOT = ROOT_DIR / "export"


def capture(cmd, *, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"command failed: {' '.join(cmd)}")
    return result.stdout.strip()


def read_sys_info_macros(path):
    macros = {}
    if not path.exists():
        return macros

    define_re = re.compile(r'^#define\s+([A-Z0-9_]+)\s+"([^"]*)"')
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            match = define_re.match(line.strip())
            if match:
                macros[match.group(1)] = match.group(2)
    return macros


def sanitize_version_component(value):
    cleaned = value.strip().lower()
    cleaned = re.sub(r"[^a-z0-9.+~-]+", ".", cleaned)
    cleaned = re.sub(r"\.{2,}", ".", cleaned).strip(".")
    return cleaned or "rolling"


def detect_git_revision(repo_dir):
    revision = capture(["git", "-C", str(repo_dir), "rev-parse", "--short", "HEAD"])
    dirty = bool(
        capture(["git", "-C", str(repo_dir), "status", "--short", "--untracked-files=no", "--", "."])
    )
    return revision, dirty


def detect_git_commit_timestamp(repo_dir):
    raw = capture(["git", "-C", str(repo_dir), "log", "-1", "--format=%ct", "HEAD"])
    return int(raw)


def build_deterministic_gpkg_version(root_dir=ROOT_DIR):
    root_dir = Path(root_dir).resolve()
    macros = read_sys_info_macros(root_dir / "src" / "sys_info.h")
    version_id = sanitize_version_component(macros.get("OS_VERSION_ID", "rolling"))
    revision, dirty = detect_git_revision(root_dir / "gpkg")
    timestamp = datetime.fromtimestamp(
        detect_git_commit_timestamp(root_dir / "gpkg"),
        tz=timezone.utc,
    ).strftime("%Y%m%d%H%M%S")
    suffix = f"{version_id}.git{timestamp}.{revision}"
    if dirty:
        suffix += ".dirty"
    return f"0+{suffix}"


def extract_revision_from_version(version):
    match = re.search(r"\.([0-9a-f]{7,40})(?:\.dirty)?$", version)
    return match.group(1) if match else ""


def version_is_dirty(version):
    return version.endswith(".dirty")


def iter_exported_gpkg_versions(export_root):
    export_root = Path(export_root).resolve()
    if not export_root.exists():
        return []

    versions = []
    for path in export_root.glob("*/gpkg/gpkg_*.gpkg"):
        arch = path.parent.parent.name
        prefix = "gpkg_"
        suffix = f"_{arch}.gpkg"
        if not path.name.startswith(prefix) or not path.name.endswith(suffix):
            continue
        version = path.name[len(prefix):-len(suffix)]
        if not version:
            continue
        versions.append(version)
    return versions


def find_matching_exported_gpkg_version(root_dir=ROOT_DIR, export_root=DEFAULT_EXPORT_ROOT):
    root_dir = Path(root_dir).resolve()
    revision, _ = detect_git_revision(root_dir / "gpkg")
    matches = []
    for version in iter_exported_gpkg_versions(export_root):
        if extract_revision_from_version(version) != revision:
            continue
        matches.append(version)
    return max(matches) if matches else ""


def default_gpkg_package_version(root_dir=ROOT_DIR, export_root=DEFAULT_EXPORT_ROOT):
    matched_export_version = find_matching_exported_gpkg_version(root_dir=root_dir, export_root=export_root)
    if matched_export_version:
        return matched_export_version
    return build_deterministic_gpkg_version(root_dir=root_dir)


def main():
    parser = argparse.ArgumentParser(description="Resolve the canonical GeminiOS gpkg package version.")
    parser.add_argument("--root-dir", default=str(ROOT_DIR), help="GeminiOS repository root")
    parser.add_argument("--export-root", default=str(DEFAULT_EXPORT_ROOT), help="Export repository root")
    parser.add_argument(
        "--deterministic",
        action="store_true",
        help="Ignore exported packages and print the deterministic fallback version",
    )
    parser.add_argument(
        "--version",
        action="store_true",
        help="Print the resolved default version (same as the default behavior)",
    )
    args = parser.parse_args()

    root_dir = Path(args.root_dir).resolve()
    export_root = Path(args.export_root).resolve()
    if args.deterministic:
        print(build_deterministic_gpkg_version(root_dir=root_dir))
    else:
        print(default_gpkg_package_version(root_dir=root_dir, export_root=export_root))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"E: {exc}", file=sys.stderr)
        sys.exit(1)

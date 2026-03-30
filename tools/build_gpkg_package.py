#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
GPKG_DIR = ROOT_DIR / "gpkg"
SYS_INFO_PATH = ROOT_DIR / "src" / "sys_info.h"
DEFAULT_SDK_DIR = Path("/home/creitin/Documents/geminios-sdk")
DEFAULT_EXPORT_ROOT = ROOT_DIR / "export"


def eprint(message):
    print(message, file=sys.stderr)


def run(cmd, *, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}")


def capture(cmd, *, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"command failed: {' '.join(cmd)}")
    return result.stdout.strip()


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def copy_file(src, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)


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
    dirty = bool(capture(["git", "-C", str(repo_dir), "status", "--short"]))
    return revision, dirty


def default_package_version():
    macros = read_sys_info_macros(SYS_INFO_PATH)
    version_id = sanitize_version_component(macros.get("OS_VERSION_ID", "rolling"))
    revision, dirty = detect_git_revision(GPKG_DIR)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    suffix = f"{version_id}.git{timestamp}.{revision}"
    if dirty:
        suffix += ".dirty"
    return f"0+{suffix}"


def build_control(args):
    return {
        "package": args.package_name,
        "version": args.version,
        "architecture": args.architecture,
        "maintainer": args.maintainer,
        "description": args.description,
        "depends": args.depends,
        "section": "admin",
        "priority": "important",
    }


def stage_install_tree(root_dir, args):
    make_cmd = ["make", "-C", str(GPKG_DIR)]
    if args.clean_first:
        run(make_cmd + ["clean"])
    run(make_cmd + ["install", f"DESTDIR={root_dir}"])

    doc_dir = root_dir / "usr" / "share" / "doc" / args.package_name
    copy_file(GPKG_DIR / "README.md", doc_dir / "README.md")
    copy_file(GPKG_DIR / "LICENSE", doc_dir / "LICENSE")


def build_package_with_sdk(sdk_dir, src_dir, output_path):
    builder = sdk_dir / "gpkg_build.py"
    if not builder.exists():
        raise FileNotFoundError(f"gpkg_build.py not found under {sdk_dir}")
    run([sys.executable, str(builder), str(src_dir), "-o", str(output_path)])


def refresh_repo_index(sdk_dir, repo_arch_dir):
    scanner = sdk_dir / "gpkg_scanrepo.py"
    if not scanner.exists():
        raise FileNotFoundError(f"gpkg_scanrepo.py not found under {sdk_dir}")
    run([sys.executable, str(scanner), str(repo_arch_dir)])


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build the GeminiOS gpkg package, export it as a .gpkg, and refresh export metadata."
    )
    parser.add_argument("--sdk-dir", default=str(DEFAULT_SDK_DIR), help="Path to the GeminiOS SDK checkout")
    parser.add_argument("--export-root", default=str(DEFAULT_EXPORT_ROOT), help="Repository export root, default: ./export")
    parser.add_argument("--package-name", default="gpkg", help="Package name, default: gpkg")
    parser.add_argument("--version", help="Override package version")
    parser.add_argument("--architecture", default="x86_64", help="Package architecture, default: x86_64")
    parser.add_argument("--maintainer", default="GeminiOS <packages@creitingameplays.com>", help="Maintainer field")
    parser.add_argument(
        "--description",
        default="GeminiOS Package Manager and worker binaries.",
        help="Package description",
    )
    parser.add_argument(
        "--subdir",
        default="gpkg",
        help="Subdirectory inside export/<arch>/ to store the built package, default: gpkg",
    )
    parser.add_argument(
        "--depends",
        nargs="*",
        default=[],
        help="Optional dependency list to place in control.json",
    )
    parser.add_argument(
        "--clean-first",
        action="store_true",
        help="Run 'make clean' in gpkg/ before building",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    args.version = args.version or default_package_version()

    sdk_dir = Path(args.sdk_dir).resolve()
    export_root = Path(args.export_root).resolve()
    repo_arch_dir = export_root / args.architecture
    target_dir = repo_arch_dir / args.subdir
    target_dir.mkdir(parents=True, exist_ok=True)

    package_filename = f"{args.package_name}_{args.version}_{args.architecture}.gpkg"
    output_path = target_dir / package_filename

    with tempfile.TemporaryDirectory(prefix="gpkg-export-src-") as tmp_dir_name:
        tmp_dir = Path(tmp_dir_name)
        src_dir = tmp_dir / args.package_name
        root_dir = src_dir / "root"
        root_dir.mkdir(parents=True, exist_ok=True)

        stage_install_tree(root_dir, args)
        write_json(src_dir / "control.json", build_control(args))
        build_package_with_sdk(sdk_dir, src_dir, output_path)

    refresh_repo_index(sdk_dir, repo_arch_dir)

    print(f"Built package: {output_path}")
    print(f"Updated index: {repo_arch_dir / 'Packages.json.zst'}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        eprint(f"E: {exc}")
        sys.exit(1)

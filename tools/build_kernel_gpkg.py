#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SDK_DIR = Path("/home/creitin/Documents/geminios-sdk")
DEFAULT_CONFIG_PATH = ROOT_DIR / "build_system" / "kernel_package_channels.json"
DEFAULT_OUTPUT_ROOT = ROOT_DIR / "output" / "kernel-packages"


def eprint(message):
    print(message, file=sys.stderr)


def run(cmd, *, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}")


def sanitize_package_suffix(value):
    lowered = value.strip().lower()
    lowered = re.sub(r"[^a-z0-9.+-]+", "-", lowered)
    lowered = re.sub(r"-{2,}", "-", lowered).strip("-")
    if not lowered:
        raise ValueError("kernel release produced an empty package suffix")
    return lowered


def load_config(path):
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def ensure_clean_dir(path):
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def copy_file(src, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)


def copy_modules_tree(src_dir, dest_dir):
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    shutil.copytree(src_dir, dest_dir, symlinks=True)


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def write_text(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write(content)


def detect_kernel_release(args):
    if args.kernel_release:
        return args.kernel_release
    if args.modules_dir:
        return Path(args.modules_dir).name
    raise ValueError("--kernel-release or --modules-dir is required")


def make_versioned_control(args, package_name, package_version, kernel_release):
    control = {
        "package": package_name,
        "version": package_version,
        "architecture": args.architecture,
        "maintainer": args.maintainer,
        "description": f"GeminiOS Linux kernel {kernel_release}",
        "section": "kernel",
        "priority": "optional",
        "provides": [
            "geminios-kernel-image",
            f"geminios-kernel-release-{sanitize_package_suffix(kernel_release)}",
        ],
    }
    return control


def make_meta_control(args, meta_package_name, package_version, versioned_package_name, channel_description):
    return {
        "package": meta_package_name,
        "version": package_version,
        "architecture": args.architecture,
        "maintainer": args.maintainer,
        "description": channel_description,
        "section": "kernel",
        "priority": "optional",
        "depends": [f"{versioned_package_name} (= {package_version})"],
    }


def generate_kernel_scripts(scripts_dir, kernel_release):
    postinst = f"""#!/bin/sh
set -e

mkdir -p /boot
ln -sfn kernel-{kernel_release} /boot/kernel

if command -v depmod >/dev/null 2>&1; then
    depmod "{kernel_release}" >/dev/null 2>&1 || true
fi
"""
    postrm = f"""#!/bin/sh
set -e

if [ -L /boot/kernel ] && [ "$(readlink /boot/kernel)" = "kernel-{kernel_release}" ]; then
    best="$(find /boot -maxdepth 1 -type f -name 'kernel-*' -printf '%f\\n' 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "$best" ]; then
        ln -sfn "$best" /boot/kernel
    else
        rm -f /boot/kernel
    fi
fi

if command -v depmod >/dev/null 2>&1; then
    depmod -a >/dev/null 2>&1 || true
fi
"""
    write_text(scripts_dir / "postinst", postinst)
    write_text(scripts_dir / "postrm", postrm)
    os.chmod(scripts_dir / "postinst", 0o755)
    os.chmod(scripts_dir / "postrm", 0o755)


def create_versioned_package_source(args, work_root, kernel_release, package_name, package_version):
    src_dir = work_root / package_name
    root_dir = src_dir / "root"
    scripts_dir = src_dir / "scripts"
    ensure_clean_dir(src_dir)
    root_dir.mkdir(parents=True, exist_ok=True)
    scripts_dir.mkdir(parents=True, exist_ok=True)

    write_json(src_dir / "control.json", make_versioned_control(args, package_name, package_version, kernel_release))

    copy_file(Path(args.bzimage), root_dir / "boot" / f"kernel-{kernel_release}")
    if args.system_map:
        copy_file(Path(args.system_map), root_dir / "boot" / f"System.map-{kernel_release}")
    if args.config_file:
        copy_file(Path(args.config_file), root_dir / "boot" / f"config-{kernel_release}")
    if args.modules_dir:
        copy_modules_tree(Path(args.modules_dir), root_dir / "lib" / "modules" / kernel_release)

    generate_kernel_scripts(scripts_dir, kernel_release)
    return src_dir


def create_meta_package_source(args, work_root, meta_package_name, package_version, versioned_package_name, channel_description):
    src_dir = work_root / meta_package_name
    ensure_clean_dir(src_dir)
    write_json(
        src_dir / "control.json",
        make_meta_control(args, meta_package_name, package_version, versioned_package_name, channel_description),
    )
    write_text(
        src_dir / "root" / "usr" / "share" / "doc" / meta_package_name / "channel",
        f"{meta_package_name} -> {versioned_package_name} ({package_version})\n",
    )
    return src_dir


def build_gpkg_package(sdk_dir, src_dir, output_path):
    builder = sdk_dir / "gpkg_build.py"
    if not builder.exists():
        raise FileNotFoundError(f"gpkg_build.py not found under {sdk_dir}")
    run([sys.executable, str(builder), str(src_dir), "-o", str(output_path)])


def scan_repo(sdk_dir, repo_arch_dir):
    scanner = sdk_dir / "gpkg_scanrepo.py"
    if not scanner.exists():
        raise FileNotFoundError(f"gpkg_scanrepo.py not found under {sdk_dir}")
    run([sys.executable, str(scanner), str(repo_arch_dir)])


def main():
    parser = argparse.ArgumentParser(
        description="Build GeminiOS kernel .gpkg packages and optional repo metadata."
    )
    parser.add_argument("--kernel-release", help="Kernel release string, for example 6.19.10-geminios")
    parser.add_argument("--bzimage", required=True, help="Path to the compiled kernel image")
    parser.add_argument("--modules-dir", help="Path to the lib/modules/<release> directory to package")
    parser.add_argument("--system-map", help="Optional System.map path")
    parser.add_argument("--config-file", help="Optional kernel .config path")
    parser.add_argument("--channel", default="stable", help="Channel name, for example stable, mainline, or next")
    parser.add_argument("--channel-package", help="Override the meta package name for the selected channel")
    parser.add_argument("--package-revision", default="1", help="Package revision suffix, default: 1")
    parser.add_argument("--maintainer", default="GeminiOS <packages@creitingameplays.com>", help="Maintainer field")
    parser.add_argument("--architecture", default="x86_64", help="Package architecture, default: x86_64")
    parser.add_argument("--sdk-dir", default=str(DEFAULT_SDK_DIR), help="Path to the GeminiOS SDK checkout")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Kernel packaging config JSON")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Workspace for generated source/package files")
    parser.add_argument("--repo-root", help="Optional repository root; when set the script copies packages into <repo-root>/<arch>/ and refreshes Packages.json.zst")
    parser.add_argument("--repo-subdir", help="Optional subdirectory inside <repo-root>/<arch>/, default comes from config")
    parser.add_argument("--skip-meta", action="store_true", help="Only build the versioned image package")
    args = parser.parse_args()

    kernel_release = detect_kernel_release(args)
    package_suffix = sanitize_package_suffix(kernel_release)
    package_version = f"{kernel_release}-{args.package_revision}"

    config = load_config(Path(args.config))
    channel_cfg = config.get("channels", {}).get(args.channel, {})
    meta_package_name = args.channel_package or channel_cfg.get("meta_package") or f"geminios-kernel-{args.channel}"
    channel_description = channel_cfg.get("description") or f"GeminiOS {args.channel} kernel channel"
    repo_subdir = args.repo_subdir or config.get("default_repo_subdir") or "kernels"

    versioned_package_name = f"geminios-kernel-image-{package_suffix}"
    sdk_dir = Path(args.sdk_dir).resolve()
    output_root = Path(args.output_root).resolve()
    work_root = output_root / "sources"
    packages_root = output_root / "packages"
    work_root.mkdir(parents=True, exist_ok=True)
    packages_root.mkdir(parents=True, exist_ok=True)

    versioned_src_dir = create_versioned_package_source(
        args,
        work_root,
        kernel_release,
        versioned_package_name,
        package_version,
    )
    versioned_output = packages_root / f"{versioned_package_name}_{package_version}_{args.architecture}.gpkg"
    build_gpkg_package(sdk_dir, versioned_src_dir, versioned_output)
    print(f"Built {versioned_output}")

    built_outputs = [versioned_output]

    if not args.skip_meta:
        meta_src_dir = create_meta_package_source(
            args,
            work_root,
            meta_package_name,
            package_version,
            versioned_package_name,
            channel_description,
        )
        meta_output = packages_root / f"{meta_package_name}_{package_version}_{args.architecture}.gpkg"
        build_gpkg_package(sdk_dir, meta_src_dir, meta_output)
        print(f"Built {meta_output}")
        built_outputs.append(meta_output)

    if args.repo_root:
        repo_arch_dir = Path(args.repo_root).resolve() / args.architecture
        target_dir = repo_arch_dir / repo_subdir
        target_dir.mkdir(parents=True, exist_ok=True)
        for package_path in built_outputs:
            shutil.copy2(package_path, target_dir / package_path.name)
        scan_repo(sdk_dir, repo_arch_dir)
        print(f"Updated repository index under {repo_arch_dir}")

    print("Kernel package build complete.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        eprint(f"E: {exc}")
        sys.exit(1)

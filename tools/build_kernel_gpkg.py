#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SDK_DIR = Path("/home/creitin/Documents/geminios-sdk")
DEFAULT_CONFIG_PATH = ROOT_DIR / "build_system" / "kernel_package_channels.json"
DEFAULT_OUTPUT_ROOT = ROOT_DIR / "output" / "kernel-packages"
DEFAULT_EXPORT_ROOT = ROOT_DIR / "export"


def eprint(message):
    print(message, file=sys.stderr)


def run(cmd, *, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}")


def compress_with_zstd(input_path, output_path):
    run(["zstd", "-q", "-f", "-T0", "-19", "-o", str(output_path), str(input_path)])


def sanitize_package_suffix(value):
    lowered = value.strip().lower()
    lowered = re.sub(r"[^a-z0-9.+-]+", "-", lowered)
    lowered = re.sub(r"-{2,}", "-", lowered).strip("-")
    if not lowered:
        raise ValueError("kernel release produced an empty package suffix")
    return lowered


def normalize_kernel_version(kernel_release):
    normalized = kernel_release.strip()
    if normalized.startswith("linux-"):
        normalized = normalized[len("linux-") :]
    normalized = normalized.lstrip("v")
    normalized = re.sub(r"-rc(\d+)", r"~rc\1", normalized)
    normalized = re.sub(r"[^\w.+~:-]+", "-", normalized)
    normalized = re.sub(r"-{2,}", "-", normalized).strip("-")
    if not normalized:
        raise ValueError("kernel release produced an empty version string")
    return normalized


def build_kernel_package_version(kernel_release, package_revision="1", build_id=None):
    base_version = normalize_kernel_version(kernel_release)
    if build_id:
        return f"{base_version}+geminios.{build_id}-{package_revision}"
    return f"{base_version}-{package_revision}"


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
    return {
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


def create_tar_from_directory(source_dir, tar_path):
    with tarfile.open(tar_path, "w", format=tarfile.PAX_FORMAT) as tar:
        for path in sorted(source_dir.rglob("*")):
            arcname = path.relative_to(source_dir)
            tar.add(path, arcname=str(arcname), recursive=False)


def package_installed_size_bytes(root_dir):
    total = 0
    for path in root_dir.rglob("*"):
        if path.is_file() and not path.is_symlink():
            total += path.stat().st_size
    return total


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha512_file(path):
    digest = hashlib.sha512()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json_file(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def build_local_package_archive(src_dir, output_path):
    with tempfile.TemporaryDirectory(prefix="gpkg-local-build-") as tmp_name:
        tmp = Path(tmp_name)
        data_tar = tmp / "data.tar"
        data_tar_zst = tmp / "data.tar.zst"
        outer_tar = tmp / "package.tar"

        create_tar_from_directory(src_dir / "root", data_tar)
        compress_with_zstd(data_tar, data_tar_zst)

        with tarfile.open(outer_tar, "w", format=tarfile.PAX_FORMAT) as tar:
            tar.add(src_dir / "control.json", arcname="control.json", recursive=False)
            tar.add(data_tar_zst, arcname="data.tar.zst", recursive=False)
            scripts_dir = src_dir / "scripts"
            if scripts_dir.exists():
                for path in sorted(scripts_dir.rglob("*")):
                    tar.add(path, arcname=str(path.relative_to(src_dir)), recursive=False)
            control_dir = src_dir / "control"
            if control_dir.exists():
                for path in sorted(control_dir.rglob("*")):
                    tar.add(path, arcname=str(path.relative_to(src_dir)), recursive=False)

        compress_with_zstd(outer_tar, output_path)


def build_package_with_sdk(sdk_dir, src_dir, output_path):
    builder = sdk_dir / "gpkg_build.py"
    if not builder.exists():
        return False
    run([sys.executable, str(builder), str(src_dir), "-o", str(output_path)])
    return True


def build_package_archive(sdk_dir, src_dir, output_path):
    if build_package_with_sdk(sdk_dir, src_dir, output_path):
        return "sdk"
    build_local_package_archive(src_dir, output_path)
    return "local"


def refresh_repo_index_with_sdk(sdk_dir, repo_arch_dir):
    scanner = sdk_dir / "gpkg_scanrepo.py"
    if not scanner.exists():
        return False
    run([sys.executable, str(scanner), str(repo_arch_dir)])
    return True


def build_repo_index_entries(repo_base_url, repo_subdir, package_specs):
    entries = []
    for package_path, src_dir in package_specs:
        control = read_json_file(src_dir / "control.json")
        root_dir = src_dir / "root"
        entry = dict(control)
        entry["filename"] = f"{repo_subdir}/{package_path.name}"
        entry["size"] = str(package_path.stat().st_size)
        entry["sha256"] = sha256_file(package_path)
        entry["sha512"] = sha512_file(package_path)
        entry["installed_size_bytes"] = str(package_installed_size_bytes(root_dir))
        entry["source_url"] = repo_base_url
        entry["repo_url"] = repo_base_url
        entry["source_kind"] = "gpkg_repo"
        entries.append(entry)
    return entries


def write_repo_index(repo_arch_dir, repo_base_url, repo_subdir, package_specs, sdk_dir):
    repo_arch_dir.mkdir(parents=True, exist_ok=True)
    if refresh_repo_index_with_sdk(sdk_dir, repo_arch_dir):
        return repo_arch_dir

    entries = build_repo_index_entries(repo_base_url, repo_subdir, package_specs)
    index_json = repo_arch_dir / "Packages.json"
    write_json(index_json, entries)
    compress_with_zstd(index_json, repo_arch_dir / "Packages.json.zst")
    return repo_arch_dir


def publish_packages_to_export(export_root, architecture, repo_subdir, built_packages, sdk_dir, repo_base_url):
    repo_arch_dir = export_root / architecture
    target_dir = repo_arch_dir / repo_subdir
    target_dir.mkdir(parents=True, exist_ok=True)
    for package_path, _ in built_packages:
        shutil.copy2(package_path, target_dir / package_path.name)
    write_repo_index(repo_arch_dir, repo_base_url, repo_subdir, built_packages, sdk_dir)
    return repo_arch_dir


def main():
    parser = argparse.ArgumentParser(
        description="Build GeminiOS kernel .gpkg packages and refresh repository metadata."
    )
    parser.add_argument("--kernel-release", help="Kernel release string, for example 7.1-rc2")
    parser.add_argument("--bzimage", required=True, help="Path to the compiled kernel image")
    parser.add_argument("--modules-dir", help="Path to the lib/modules/<release> directory to package")
    parser.add_argument("--system-map", help="Optional System.map path")
    parser.add_argument("--config-file", help="Optional kernel .config path")
    parser.add_argument("--channel", default="stable", help="Channel name, for example stable, mainline, or next")
    parser.add_argument("--channel-package", help="Override the meta package name for the selected channel")
    parser.add_argument("--package-revision", default="1", help="Package revision suffix, default: 1")
    parser.add_argument("--build-id", help="Optional build metadata suffix for the package version")
    parser.add_argument("--maintainer", default="GeminiOS <packages@creitingameplays.com>", help="Maintainer field")
    parser.add_argument("--architecture", default="x86_64", help="Package architecture, default: x86_64")
    parser.add_argument("--sdk-dir", default=str(DEFAULT_SDK_DIR), help="Path to the GeminiOS SDK checkout")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Kernel packaging config JSON")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Workspace for generated source/package files")
    parser.add_argument(
        "--export-root",
        default=str(DEFAULT_EXPORT_ROOT),
        help="Export root to publish built packages and refresh Packages.json.zst, default: ./export",
    )
    parser.add_argument(
        "--repo-root",
        help="Deprecated alias for --export-root; when set it overrides the export destination",
    )
    parser.add_argument("--repo-subdir", help="Optional subdirectory inside <export-root>/<arch>/, default comes from config")
    parser.add_argument("--skip-meta", action="store_true", help="Only build the versioned image package")
    args = parser.parse_args()

    kernel_release = detect_kernel_release(args)
    package_suffix = sanitize_package_suffix(kernel_release)
    package_version = build_kernel_package_version(kernel_release, args.package_revision, args.build_id)

    config = load_config(Path(args.config))
    channel_cfg = config.get("channels", {}).get(args.channel, {})
    meta_package_name = args.channel_package or channel_cfg.get("meta_package") or f"geminios-kernel-{args.channel}"
    channel_description = channel_cfg.get("description") or f"GeminiOS {args.channel} kernel channel"
    repo_subdir = args.repo_subdir or config.get("default_repo_subdir") or "kernels"
    repo_base_url = config.get("default_repo_base_url") or "https://repo.creitingameplays.com"

    versioned_package_name = f"geminios-kernel-image-{package_suffix}"
    sdk_dir = Path(args.sdk_dir).resolve()
    output_root = Path(args.output_root).resolve()
    export_root = Path(args.repo_root or args.export_root).resolve()
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
    build_mode = build_package_archive(sdk_dir, versioned_src_dir, versioned_output)
    print(f"Built {versioned_output} ({build_mode})")

    built_outputs = [(versioned_output, versioned_src_dir)]

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
        build_mode = build_package_archive(sdk_dir, meta_src_dir, meta_output)
        print(f"Built {meta_output} ({build_mode})")
        built_outputs.append((meta_output, meta_src_dir))

    repo_arch_dir = publish_packages_to_export(
        export_root,
        args.architecture,
        repo_subdir,
        built_outputs,
        sdk_dir,
        repo_base_url,
    )
    print(f"Published packages under {repo_arch_dir / repo_subdir}")
    print(f"Updated index: {repo_arch_dir / 'Packages.json.zst'}")

    print("Kernel package build complete.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        eprint(f"E: {exc}")
        sys.exit(1)

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REQUIRED_CONTROL_FIELDS = ("package", "version", "architecture", "maintainer", "description")


def env_flag(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def env_list(name: str, default: str) -> list[str]:
    raw = os.getenv(name, default)
    return [item for item in (part.strip() for part in raw.split(":")) if item]


def log(message: str) -> None:
    print(f"[gpkg-publisher] {message}", flush=True)


def run(cmd: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(cmd, cwd=str(cwd) if cwd else None, check=True)


@dataclass(frozen=True)
class Config:
    package_roots: tuple[Path, ...]
    work_root: Path
    publish_root: Path
    gpkg_build_bin: str
    gpkg_scanrepo_bin: str
    build_jobs: int
    run_build_hooks: bool
    publish_enabled: bool
    keep_failed_run: bool
    upload_backend: str
    rclone_remote: str
    rclone_extra_args: tuple[str, ...]
    lock_file: Path


@dataclass(frozen=True)
class PackageSpec:
    directory: Path
    package: str
    version: str
    architecture: str

    @property
    def output_name(self) -> str:
        return f"{self.package}_{self.version}_{self.architecture}.gpkg"


def load_config() -> Config:
    package_roots = tuple(Path(path).expanduser().resolve() for path in env_list("PACKAGE_ROOTS", "./packages"))
    work_root = Path(os.getenv("WORK_ROOT", "./var/gpkg-publisher")).expanduser().resolve()
    publish_root = Path(os.getenv("PUBLISH_ROOT", "./public/gpkg-repo")).expanduser().resolve()
    gpkg_build_bin = os.getenv("GPKG_BUILD_BIN", "gpkg-build")
    gpkg_scanrepo_bin = os.getenv("GPKG_SCANREPO_BIN", "gpkg-scanrepo")
    build_jobs = max(1, int(os.getenv("BUILD_JOBS", str(os.cpu_count() or 1))))
    run_build_hooks = env_flag("RUN_BUILD_HOOKS", True)
    publish_enabled = env_flag("PUBLISH_ENABLED", True)
    keep_failed_run = env_flag("KEEP_FAILED_RUN", True)
    upload_backend = os.getenv("UPLOAD_BACKEND", "rclone").strip().lower()
    rclone_remote = os.getenv("RCLONE_REMOTE", "").strip()
    rclone_extra_args = tuple(arg for arg in os.getenv("RCLONE_EXTRA_ARGS", "").split() if arg)
    lock_file = Path(os.getenv("LOCK_FILE", str(work_root / "publish.lock"))).expanduser().resolve()
    return Config(
        package_roots=package_roots,
        work_root=work_root,
        publish_root=publish_root,
        gpkg_build_bin=gpkg_build_bin,
        gpkg_scanrepo_bin=gpkg_scanrepo_bin,
        build_jobs=build_jobs,
        run_build_hooks=run_build_hooks,
        publish_enabled=publish_enabled,
        keep_failed_run=keep_failed_run,
        upload_backend=upload_backend,
        rclone_remote=rclone_remote,
        rclone_extra_args=rclone_extra_args,
        lock_file=lock_file,
    )


def validate_config(config: Config) -> None:
    missing_roots = [path for path in config.package_roots if not path.exists()]
    if missing_roots:
        joined = ", ".join(str(path) for path in missing_roots)
        raise RuntimeError(f"Missing package roots: {joined}")

    shutil.which(config.gpkg_build_bin) or _raise_missing_bin(config.gpkg_build_bin)
    shutil.which(config.gpkg_scanrepo_bin) or _raise_missing_bin(config.gpkg_scanrepo_bin)
    shutil.which("rsync") or _raise_missing_bin("rsync")

    if config.publish_enabled and config.upload_backend == "rclone":
        shutil.which("rclone") or _raise_missing_bin("rclone")
        if not config.rclone_remote:
            raise RuntimeError("RCLONE_REMOTE must be set when publish is enabled with the rclone backend.")


def _raise_missing_bin(binary: str) -> None:
    raise RuntimeError(f"Missing required command: {binary}")


def discover_packages(config: Config) -> list[PackageSpec]:
    packages: list[PackageSpec] = []
    seen: set[Path] = set()

    for root in config.package_roots:
        for control_file in sorted(root.rglob("control.json")):
            package_dir = control_file.parent.resolve()
            if package_dir in seen:
                continue
            seen.add(package_dir)
            packages.append(load_package_spec(package_dir))

    if not packages:
        raise RuntimeError("No package directories with control.json were found.")

    sorted_packages = sorted(
        packages,
        key=lambda pkg: (pkg.architecture, pkg.package, pkg.version, str(pkg.directory)),
    )
    detect_duplicate_outputs(sorted_packages)
    return sorted_packages


def load_package_spec(package_dir: Path) -> PackageSpec:
    control_path = package_dir / "control.json"
    with control_path.open("r", encoding="utf-8") as handle:
        metadata = json.load(handle)

    for field in REQUIRED_CONTROL_FIELDS:
        if field not in metadata:
            raise RuntimeError(f"Missing required field '{field}' in {control_path}")

    return PackageSpec(
        directory=package_dir,
        package=str(metadata["package"]),
        version=str(metadata["version"]),
        architecture=str(metadata["architecture"]),
    )


def detect_duplicate_outputs(packages: Iterable[PackageSpec]) -> None:
    outputs: dict[tuple[str, str], Path] = {}
    for package in packages:
        key = (package.architecture, package.output_name)
        previous = outputs.get(key)
        if previous is not None:
            raise RuntimeError(
                "Duplicate package output detected for "
                f"{package.output_name}: {previous} and {package.directory}"
            )
        outputs[key] = package.directory


def run_build_hook(package: PackageSpec) -> None:
    hook = package.directory / "build.sh"
    if hook.exists():
        log(f"Running build hook for {package.package}: {hook}")
        run(["bash", str(hook)], cwd=package.directory)


def build_package(package: PackageSpec, config: Config, stage_repo_root: Path) -> Path:
    if config.run_build_hooks:
        run_build_hook(package)

    arch_dir = stage_repo_root / package.architecture
    arch_dir.mkdir(parents=True, exist_ok=True)
    output_path = arch_dir / package.output_name

    log(f"Building {package.package} {package.version} [{package.architecture}]")
    run([config.gpkg_build_bin, str(package.directory), "-o", str(output_path)])
    return output_path


def build_all_packages(packages: Iterable[PackageSpec], config: Config, stage_repo_root: Path) -> list[Path]:
    outputs: list[Path] = []
    package_list = list(packages)

    if config.build_jobs == 1:
        for package in package_list:
            outputs.append(build_package(package, config, stage_repo_root))
        return outputs

    with concurrent.futures.ThreadPoolExecutor(max_workers=config.build_jobs) as executor:
        futures = {
            executor.submit(build_package, package, config, stage_repo_root): package
            for package in package_list
        }
        for future in concurrent.futures.as_completed(futures):
            package = futures[future]
            try:
                outputs.append(future.result())
            except Exception as exc:
                raise RuntimeError(f"Failed to build {package.package} from {package.directory}: {exc}") from exc

    return outputs


def scan_architectures(config: Config, stage_repo_root: Path) -> None:
    arch_dirs = sorted(path for path in stage_repo_root.iterdir() if path.is_dir())
    if not arch_dirs:
        raise RuntimeError(f"No architecture directories were produced in {stage_repo_root}")

    for arch_dir in arch_dirs:
        log(f"Generating repository index for {arch_dir.name}")
        run([config.gpkg_scanrepo_bin, str(arch_dir)])


def sync_repo(stage_repo_root: Path, publish_root: Path) -> None:
    publish_root.mkdir(parents=True, exist_ok=True)
    run(["rsync", "-a", "--delete", f"{stage_repo_root}/", f"{publish_root}/"])


def upload_repo(config: Config) -> None:
    if not config.publish_enabled:
        log("Upload disabled; leaving generated repository on disk only.")
        return

    if config.upload_backend == "none":
        log("Upload backend set to 'none'; leaving generated repository on disk only.")
        return

    if config.upload_backend != "rclone":
        raise RuntimeError(f"Unsupported UPLOAD_BACKEND '{config.upload_backend}'")

    cmd = ["rclone", "sync", str(config.publish_root), config.rclone_remote, *config.rclone_extra_args]
    log(f"Uploading repository with rclone to {config.rclone_remote}")
    run(cmd)


def with_lock(lock_file: Path):
    lock_file.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_file.open("w", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError(f"Another publish run is already active: {lock_file}")
    return handle


def main() -> int:
    parser = argparse.ArgumentParser(description="Build GeminiOS .gpkg packages and publish a repository.")
    parser.add_argument("--list-packages", action="store_true", help="List discovered package directories and exit.")
    args = parser.parse_args()

    config = load_config()

    try:
        validate_config(config)
        lock_handle = with_lock(config.lock_file)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    with lock_handle:
        try:
            packages = discover_packages(config)
            if args.list_packages:
                for package in packages:
                    print(f"{package.package}\t{package.version}\t{package.architecture}\t{package.directory}")
                return 0

            config.work_root.mkdir(parents=True, exist_ok=True)
            run_root = Path(tempfile.mkdtemp(prefix="run-", dir=config.work_root))
            stage_repo_root = run_root / "repo"
            stage_repo_root.mkdir(parents=True, exist_ok=True)

            log(f"Discovered {len(packages)} package directories")
            build_all_packages(packages, config, stage_repo_root)
            scan_architectures(config, stage_repo_root)
            sync_repo(stage_repo_root, config.publish_root)
            upload_repo(config)
            shutil.rmtree(run_root, ignore_errors=True)
            log(f"Repository published successfully at {config.publish_root}")
            return 0
        except Exception as exc:
            print(f"error: {exc}", file=sys.stderr)
            if "run_root" in locals() and not config.keep_failed_run:
                shutil.rmtree(run_root, ignore_errors=True)
            elif "run_root" in locals():
                log(f"Preserved failed run artifacts at {run_root}")
            return 1


if __name__ == "__main__":
    sys.exit(main())

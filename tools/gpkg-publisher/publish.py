#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from common import (  # noqa: E402
    DEFAULT_BLOCKLIST,
    DEFAULT_SYSTEM_PROVIDES_FILE,
    DEFAULT_SYSTEM_UPGRADEABLE_FILE,
    apt_candidate_version,
    build_provider_resolver,
    collect_dependency_relation_text,
    choose_first_matching_stanza,
    ensure_directory,
    hash_file,
    load_env_file,
    matches_any,
    merge_system_provided_patterns,
    normalize_dependency_field,
    parse_control_stanzas,
    read_pattern_file,
    read_json,
    read_seed_packages,
    run,
    safe_filename_component,
    scan_repo,
    write_json,
)
from import_deb import convert_deb_to_gpkg, get_output_path_for_fields  # noqa: E402


DEFAULT_CONFIG = {
    "ARCH": "x86_64",
    "APT_ARCH": "amd64",
    "DISCOVERY_MODE": "seeds",
    "REPO_ROOT": "/var/lib/gpkg-publisher/repo",
    "DOWNLOAD_DIR": "/var/lib/gpkg-publisher/cache/debs",
    "TEMP_DIR": "/var/lib/gpkg-publisher/tmp",
    "STATE_FILE": "/var/lib/gpkg-publisher/state/state.json",
    "REPORT_FILE": "/var/lib/gpkg-publisher/state/last-run.json",
    "SEED_FILE": "/etc/gpkg-publisher/packages.txt",
    "OVERRIDES_FILE": "/etc/gpkg-publisher/overrides.json",
    "SYSTEM_PROVIDES_FILE": str(DEFAULT_SYSTEM_PROVIDES_FILE),
    "SYSTEM_UPGRADEABLE_FILE": str(DEFAULT_SYSTEM_UPGRADEABLE_FILE),
    "SECTION_ALLOWLIST": "",
    "SECTION_BLOCKLIST": "debug,doc,devel,kernel,libdevel,metapackages,oldlibs",
    "PRIORITY_BLOCKLIST": "required,important",
    "PACKAGE_LIMIT": "0",
    "ZSTD_LEVEL": "10",
    "INDEX_ZSTD_LEVEL": "19",
    "UPLOAD_ENABLED": "1",
    "INCLUDE_MAINTAINER_SCRIPTS": "0",
    "INCLUDE_RECOMMENDS": "1",
    "ALLOW_ESSENTIAL": "0",
    "RCLONE_DEST": "",
    "RCLONE_CONFIG": "",
    "RCLONE_EXTRA_ARGS": "",
    "UPLOAD_COMMAND": "",
    "BLOCKLIST_PATTERNS": ",".join(DEFAULT_BLOCKLIST),
}


@dataclass
class ResolvedPackage:
    name: str
    version: str
    deb_filename: str
    fields: dict[str, str]
    depends: list[str]


class AptResolver:
    def __init__(
        self,
        *,
        apt_arch: str,
        overrides: dict[str, Any],
        blocklist_patterns: list[str],
        system_provided_patterns: list[str],
        allow_essential: bool,
        include_recommends: bool,
        verbose: bool,
    ) -> None:
        self.apt_arch = apt_arch
        self.overrides = overrides
        self.blocklist_patterns = blocklist_patterns
        self.system_provided_patterns = system_provided_patterns
        self.allow_essential = allow_essential
        self.include_recommends = include_recommends
        self.verbose = verbose
        self.package_cache: dict[str, ResolvedPackage | None] = {}
        self.resolved: dict[str, ResolvedPackage] = {}
        self.order: list[ResolvedPackage] = []
        self.failures: dict[str, str] = {}
        self.skipped: dict[str, str] = {}
        self.active: set[str] = set()
        self.explicit_packages: set[str] = set()
        self.provider_resolver = build_provider_resolver(
            apt_arch=self.apt_arch,
            overrides=self.overrides,
            provider_exists=self._provider_target_exists,
            verbose=self.verbose,
        )

    def candidate_exists(self, package_name: str) -> bool:
        if matches_any(package_name, self.system_provided_patterns):
            return True
        if self._apt_candidate_version(package_name) is not None:
            return True
        provider_name = self.provider_resolver(package_name)
        if provider_name is None:
            return False
        return self._provider_target_exists(provider_name)

    def resolve_all(self, packages: list[str]) -> tuple[list[ResolvedPackage], dict[str, str], dict[str, str]]:
        self.explicit_packages = set(packages)
        for package_name in packages:
            self._resolve_one(package_name, parent=None)
        return self.order, self.failures, self.skipped

    def _resolve_one(self, package_name: str, *, parent: str | None) -> bool:
        if package_name in self.resolved:
            return True
        if package_name in self.failures:
            return False
        if package_name in self.skipped:
            return False
        if package_name in self.active:
            return True
        if matches_any(package_name, self.system_provided_patterns):
            return True
        if matches_any(package_name, self.blocklist_patterns):
            if parent is None:
                self.skipped[package_name] = "blocked by pattern"
            else:
                self.failures[package_name] = "blocked by pattern"
            return False
        provider_name = self.provider_resolver(package_name)
        if provider_name and provider_name != package_name:
            if not self._resolve_one(provider_name, parent=package_name):
                self.failures[package_name] = f"provider {provider_name} could not be resolved"
                return False
            if provider_name in self.resolved:
                self.resolved[package_name] = self.resolved[provider_name]
            return True

        package = self._load_package(package_name)
        if package is None:
            self.failures[package_name] = "no APT candidate"
            return False

        self.active.add(package_name)
        for dep_spec in package.depends:
            dep_name = dep_spec.split(" ", 1)[0]
            if not self._resolve_one(dep_name, parent=package_name):
                self.failures[package_name] = f"dependency {dep_name} could not be resolved"
                self.active.remove(package_name)
                return False

        self.active.remove(package_name)
        self.resolved[package_name] = package
        self.order.append(package)
        return True

    def _load_package(self, package_name: str) -> ResolvedPackage | None:
        if package_name in self.package_cache:
            return self.package_cache[package_name]

        if matches_any(package_name, self.blocklist_patterns):
            self.package_cache[package_name] = None
            return None

        candidate = self._apt_candidate_version(package_name)
        if candidate is None:
            self.package_cache[package_name] = None
            return None

        show_output = run(
            ["apt-cache", "show", package_name],
            capture=True,
            verbose=self.verbose,
        ).stdout
        stanzas = parse_control_stanzas(show_output)
        fields = choose_first_matching_stanza(stanzas, package_name, candidate, self.apt_arch)
        if fields is None:
            self.package_cache[package_name] = None
            return None

        if fields.get("Essential", "no").lower() == "yes" and not self.allow_essential:
            self.package_cache[package_name] = None
            self.failures.setdefault(package_name, "package is marked Essential: yes")
            return None

        filename = fields.get("Filename", "")
        if not filename:
            self.package_cache[package_name] = None
            return None

        dependency_choices = self.overrides.get("dependency_choices", {})
        dependency_rewrites = self.overrides.get("dependency_rewrites", {})
        skip_patterns = list(self.blocklist_patterns)
        skip_patterns.extend(self.overrides.get("skip_dependency_patterns", []))
        drop_patterns = self.overrides.get("provided_by_system_patterns", [])
        depends = normalize_dependency_field(
            collect_dependency_relation_text(
                fields,
                include_recommends=self.include_recommends and package_name in self.explicit_packages,
            ),
            package_name=package_name,
            apt_arch=self.apt_arch,
            dependency_choices=dependency_choices,
            dependency_rewrites=dependency_rewrites,
            dependency_exists=self.candidate_exists,
            skip_patterns=skip_patterns,
            drop_patterns=drop_patterns,
            provider_resolver=self.provider_resolver,
        )

        package_override = self.overrides.get("package_overrides", {}).get(package_name, {})
        depends = [dep for dep in depends if dep not in package_override.get("depends_remove", [])]
        depends.extend(package_override.get("depends_add", []))

        resolved = ResolvedPackage(
            name=package_name,
            version=candidate,
            deb_filename=Path(filename).name,
            fields=fields,
            depends=sorted(set(depends)),
        )
        self.package_cache[package_name] = resolved
        return resolved

    def _apt_candidate_version(self, package_name: str) -> str | None:
        return apt_candidate_version(package_name, verbose=self.verbose)

    def _provider_target_exists(self, package_name: str) -> bool:
        return matches_any(package_name, self.system_provided_patterns) or self._apt_candidate_version(package_name) is not None


def parse_bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def load_config(config_path: Path) -> dict[str, str]:
    config = dict(DEFAULT_CONFIG)
    config.update(load_env_file(config_path))
    for key in config:
        if key in os.environ:
            config[key] = os.environ[key]
    return config


def split_patterns(raw_value: str) -> list[str]:
    return [item.strip() for item in raw_value.split(",") if item.strip()]


def discover_all_packages(
    *,
    apt_arch: str,
    blocklist_patterns: list[str],
    system_provided_patterns: list[str],
    allow_essential: bool,
    section_allowlist: list[str],
    section_blocklist: list[str],
    priority_blocklist: list[str],
    verbose: bool,
) -> list[str]:
    discovered: list[str] = []
    seen: set[str] = set()
    dumpavail = run(["apt-cache", "dumpavail"], capture=True, verbose=verbose).stdout

    for fields in parse_control_stanzas(dumpavail):
        package_name = fields.get("Package", "").strip()
        if not package_name or package_name in seen:
            continue
        if matches_any(package_name, system_provided_patterns):
            continue
        if matches_any(package_name, blocklist_patterns):
            continue

        package_arch = fields.get("Architecture", "").strip()
        if package_arch not in {"", "all", apt_arch}:
            continue

        if fields.get("Essential", "no").lower() == "yes" and not allow_essential:
            continue

        section = fields.get("Section", "misc").split("/", 1)[0].strip().lower()
        if section_allowlist and section not in section_allowlist:
            continue
        if section in section_blocklist:
            continue

        priority = fields.get("Priority", "").strip().lower()
        if priority in priority_blocklist:
            continue

        seen.add(package_name)
        discovered.append(package_name)

    return sorted(discovered)


def download_deb(package: ResolvedPackage, download_dir: Path, *, verbose: bool) -> Path:
    ensure_directory(download_dir)
    expected_path = download_dir / package.deb_filename
    if expected_path.exists():
        return expected_path

    before = {path.name for path in download_dir.glob("*.deb")}
    run(
        ["apt-get", "download", f"{package.name}={package.version}"],
        cwd=download_dir,
        verbose=verbose,
    )
    after = {path.name for path in download_dir.glob("*.deb")}
    created = sorted(after - before)
    if expected_path.exists():
        return expected_path
    if len(created) == 1:
        return download_dir / created[0]

    prefix = f"{package.name}_{safe_filename_component(package.version)}"
    matches = sorted(path for path in download_dir.glob(f"{prefix}*.deb"))
    if matches:
        return matches[-1]

    raise RuntimeError(f"Could not locate downloaded .deb for {package.name} {package.version}")


def build_upload_command(config: dict[str, str], repo_root: Path) -> list[str] | None:
    upload_command = config.get("UPLOAD_COMMAND", "").strip()
    if upload_command:
        rendered = upload_command.format(repo_root=repo_root, arch_dir=repo_root / config["ARCH"])
        return shlex.split(rendered)

    rclone_dest = config.get("RCLONE_DEST", "").strip()
    if not rclone_dest:
        return None

    command = ["rclone"]
    rclone_config = config.get("RCLONE_CONFIG", "").strip()
    if rclone_config:
        config_path = Path(rclone_config).expanduser()
        if not config_path.exists():
            raise RuntimeError(f"RCLONE_CONFIG does not exist: {config_path}")
        if not os.access(config_path, os.R_OK):
            raise RuntimeError(
                f"RCLONE_CONFIG is not readable by the current user: {config_path}. "
                "Fix ownership or permissions."
            )
        command.extend(["--config", rclone_config])
    command.extend(["copy", str(repo_root), rclone_dest, "--fast-list", "--checksum"])
    extra_args = config.get("RCLONE_EXTRA_ARGS", "").strip()
    if extra_args:
        command.extend(shlex.split(extra_args))
    return command


def build_fingerprint(
    package: ResolvedPackage,
    *,
    deb_sha256: str,
    overrides: dict[str, Any],
    system_provided_patterns: list[str],
    zstd_level: int,
    include_maintainer_scripts: bool,
    include_recommends: bool,
) -> str:
    package_override = overrides.get("package_overrides", {}).get(package.name, {})
    payload = {
        "package": package.name,
        "version": package.version,
        "deb_sha256": deb_sha256,
        "zstd_level": zstd_level,
        "include_maintainer_scripts": include_maintainer_scripts,
        "include_recommends": include_recommends,
        "package_override": package_override,
        "dependency_choices": overrides.get("dependency_choices", {}),
        "dependency_rewrites": overrides.get("dependency_rewrites", {}),
        "skip_dependency_patterns": overrides.get("skip_dependency_patterns", []),
        "provided_by_system_patterns": system_provided_patterns,
        "skip_packages": overrides.get("skip_packages", []),
        "skip_patterns": overrides.get("skip_patterns", []),
    }
    encoded = json.dumps(payload, sort_keys=True).encode()
    return hash_file_from_bytes(encoded)


def hash_file_from_bytes(payload: bytes) -> str:
    import hashlib

    return hashlib.sha256(payload).hexdigest()


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def build_sidecar_path(output_path: Path) -> Path:
    return output_path.with_name(output_path.name + ".build.json")


def load_sidecar(output_path: Path) -> dict[str, Any]:
    return read_json(build_sidecar_path(output_path), {})


def write_sidecar(output_path: Path, payload: dict[str, Any]) -> None:
    write_json(build_sidecar_path(output_path), payload)


def translate_legacy_repo_filename(name: str) -> str:
    return name.replace("%3a", ":").replace("%3A", ":")


def migrate_legacy_repo_filenames(repo_arch_dir: Path, *, verbose: bool) -> dict[str, str]:
    migrations: dict[str, str] = {}

    for legacy_path in sorted(repo_arch_dir.rglob("*.gpkg")):
        target_name = translate_legacy_repo_filename(legacy_path.name)
        if target_name == legacy_path.name:
            continue

        target_path = legacy_path.with_name(target_name)
        legacy_sidecar = build_sidecar_path(legacy_path)
        target_sidecar = build_sidecar_path(target_path)

        if target_path.exists():
            if hash_file(target_path) != hash_file(legacy_path):
                raise RuntimeError(
                    f"Cannot migrate {legacy_path} to {target_path}: target already exists with different contents"
                )
            legacy_path.unlink()
        else:
            if verbose:
                print(f"Migrating repo filename {legacy_path.name} -> {target_path.name}")
            legacy_path.rename(target_path)

        if legacy_sidecar.exists():
            if target_sidecar.exists():
                legacy_sidecar.unlink()
            else:
                legacy_sidecar.rename(target_sidecar)

        migrations[str(legacy_path)] = str(target_path)

    return migrations


def apply_path_migrations_to_state(package_state: dict[str, Any], migrations: dict[str, str]) -> bool:
    changed = False
    for payload in package_state.values():
        output_path = payload.get("output_path")
        if output_path in migrations:
            payload["output_path"] = migrations[output_path]
            changed = True
    return changed


def load_existing_gpkg_metadata(package_path: Path, *, temp_root: Path) -> dict[str, Any]:
    ensure_directory(temp_root)
    with tempfile.TemporaryDirectory(prefix="gpkg-reuse-", dir=str(temp_root)) as temp_dir_name:
        temp_tar = Path(temp_dir_name) / "package.tar"
        with temp_tar.open("wb") as handle:
            completed = subprocess.run(
                ["zstd", "-dc", str(package_path)],
                stdout=handle,
                stderr=subprocess.PIPE,
                text=False,
            )
        if completed.returncode != 0:
            error = completed.stderr.decode(errors="replace").strip()
            raise RuntimeError(f"Failed to inspect existing package {package_path}: {error}")

        with tarfile.open(temp_tar, "r") as tar:
            control_handle = tar.extractfile("control.json")
            if control_handle is None:
                raise RuntimeError(f"Existing package is missing control.json: {package_path}")
            return json.load(control_handle)


def persist_progress(
    *,
    state_file: Path,
    report_file: Path,
    state: dict[str, Any],
    report: dict[str, Any],
) -> None:
    report["last_checkpoint_at"] = now_utc()
    write_json(state_file, state)
    write_json(report_file, report)


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve Debian packages, convert them to .gpkg, index a repo, and optionally upload it.")
    parser.add_argument("--config", default=str(SCRIPT_DIR / "config.env"), help="Path to the publisher env file")
    parser.add_argument("--package", action="append", default=[], help="Additional seed package to resolve")
    parser.add_argument("--all-packages", action="store_true", help="Ignore the seed file and discover packages from the local APT cache")
    parser.add_argument("--skip-upload", action="store_true", help="Do everything except the final upload")
    parser.add_argument("--force-import", action="store_true", help="Rebuild every gpkg even if state says it is up to date")
    parser.add_argument("--dry-run", action="store_true", help="Resolve and print the plan without downloading or publishing")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show executed commands")
    args = parser.parse_args()

    config = load_config(Path(args.config))
    overrides = read_json(Path(config["OVERRIDES_FILE"]), {}) if config["OVERRIDES_FILE"] else {}
    system_provides_file = Path(config["SYSTEM_PROVIDES_FILE"]).expanduser()
    system_provided_patterns = read_pattern_file(system_provides_file)
    system_upgradeable_file = Path(config["SYSTEM_UPGRADEABLE_FILE"]).expanduser()
    system_upgradeable_patterns = read_pattern_file(system_upgradeable_file)
    extra_system_patterns = overrides.get("provided_by_system_patterns", [])
    system_provided_patterns = merge_system_provided_patterns(
        base_patterns=system_provided_patterns,
        extra_patterns=extra_system_patterns,
        upgradeable_patterns=system_upgradeable_patterns,
        verbose=args.verbose,
    )
    overrides["provided_by_system_patterns"] = system_provided_patterns
    blocklist_patterns = split_patterns(config["BLOCKLIST_PATTERNS"])

    repo_root = Path(config["REPO_ROOT"]).expanduser()
    repo_arch_dir = repo_root / config["ARCH"]
    download_dir = Path(config["DOWNLOAD_DIR"]).expanduser()
    temp_dir = Path(config["TEMP_DIR"]).expanduser()
    state_file = Path(config["STATE_FILE"]).expanduser()
    report_file = Path(config["REPORT_FILE"]).expanduser()
    seed_file = Path(config["SEED_FILE"]).expanduser()
    include_maintainer_scripts = parse_bool(config["INCLUDE_MAINTAINER_SCRIPTS"])
    include_recommends = parse_bool(config["INCLUDE_RECOMMENDS"])
    allow_essential = parse_bool(config["ALLOW_ESSENTIAL"])
    upload_enabled = parse_bool(config["UPLOAD_ENABLED"]) and not args.skip_upload
    zstd_level = int(config["ZSTD_LEVEL"])
    index_zstd_level = int(config["INDEX_ZSTD_LEVEL"])
    package_limit = int(config["PACKAGE_LIMIT"])
    section_allowlist = [item.lower() for item in split_patterns(config["SECTION_ALLOWLIST"])]
    section_blocklist = [item.lower() for item in split_patterns(config["SECTION_BLOCKLIST"])]
    priority_blocklist = [item.lower() for item in split_patterns(config["PRIORITY_BLOCKLIST"])]

    ensure_directory(repo_arch_dir)
    ensure_directory(download_dir)
    ensure_directory(temp_dir)
    ensure_directory(state_file.parent)
    ensure_directory(report_file.parent)

    discovery_mode = config["DISCOVERY_MODE"].strip().lower()
    use_all_packages = args.all_packages or discovery_mode == "all"

    if use_all_packages:
        seeds = discover_all_packages(
            apt_arch=config["APT_ARCH"],
            blocklist_patterns=blocklist_patterns,
            system_provided_patterns=system_provided_patterns,
            allow_essential=allow_essential,
            section_allowlist=section_allowlist,
            section_blocklist=section_blocklist,
            priority_blocklist=priority_blocklist,
            verbose=args.verbose,
        )
    else:
        seeds = read_seed_packages(seed_file)

    seeds.extend(args.package)
    seeds = list(dict.fromkeys(seeds))
    if package_limit > 0:
        seeds = seeds[:package_limit]
    if not seeds:
        print("error: no seed packages were provided", file=sys.stderr)
        return 1

    resolver = AptResolver(
        apt_arch=config["APT_ARCH"],
        overrides=overrides,
        blocklist_patterns=blocklist_patterns,
        system_provided_patterns=system_provided_patterns,
        allow_essential=allow_essential,
        include_recommends=include_recommends,
        verbose=args.verbose,
    )
    packages, failures, skipped = resolver.resolve_all(seeds)

    report: dict[str, Any] = {
        "started_at": now_utc(),
        "discovery_mode": "all" if use_all_packages else "seeds",
        "seed_packages": seeds,
        "resolved_count": len(packages),
        "resolved_packages": [package.name for package in packages],
        "skipped": skipped.copy(),
        "failures": failures.copy(),
        "built": [],
        "reused": [],
        "uploaded": False,
    }

    if args.dry_run:
        print(json.dumps(report, indent=2))
        return 1 if failures else 0

    state = read_json(state_file, {"packages": {}})
    package_state = state.setdefault("packages", {})
    path_migrations = migrate_legacy_repo_filenames(repo_arch_dir, verbose=args.verbose)
    if path_migrations:
        if apply_path_migrations_to_state(package_state, path_migrations):
            persist_progress(
                state_file=state_file,
                report_file=report_file,
                state=state,
                report=report,
            )

    for package in packages:
        try:
            deb_path = download_deb(package, download_dir, verbose=args.verbose)
            deb_sha256 = hash_file(deb_path)
            fingerprint = build_fingerprint(
                package,
                deb_sha256=deb_sha256,
                overrides=overrides,
                system_provided_patterns=system_provided_patterns,
                zstd_level=zstd_level,
                include_maintainer_scripts=include_maintainer_scripts,
                include_recommends=include_recommends,
            )
            expected_output_path = get_output_path_for_fields(
                package.fields,
                repo_arch_dir=repo_arch_dir,
                overrides=overrides,
                apt_arch=config["APT_ARCH"],
            )
            legacy_output_path = get_output_path_for_fields(
                package.fields,
                repo_arch_dir=repo_arch_dir,
                overrides=overrides,
                apt_arch=config["APT_ARCH"],
                legacy_filename=True,
            )

            cached = package_state.get(package.name, {})
            output_path_value = cached.get("output_path")
            output_path = Path(output_path_value) if output_path_value else None
            sidecar_candidates: list[Path] = []
            if output_path is not None:
                sidecar_candidates.append(output_path)
            if expected_output_path not in sidecar_candidates:
                sidecar_candidates.append(expected_output_path)
            if legacy_output_path not in sidecar_candidates:
                sidecar_candidates.append(legacy_output_path)

            if (
                not args.force_import
                and cached.get("fingerprint") == fingerprint
                and output_path is not None
                and output_path.exists()
            ):
                report["reused"].append(package.name)
                package_state[package.name] = {
                    "version": package.version,
                    "deb_sha256": deb_sha256,
                    "fingerprint": fingerprint,
                    "output_path": str(output_path),
                    "updated_at": now_utc(),
                }
                write_sidecar(output_path, package_state[package.name])
                persist_progress(
                    state_file=state_file,
                    report_file=report_file,
                    state=state,
                    report=report,
                )
                continue

            if not args.force_import:
                reused_from_sidecar = False
                for candidate in sidecar_candidates:
                    if not candidate.exists():
                        continue
                    sidecar = load_sidecar(candidate)
                    if sidecar.get("fingerprint") != fingerprint:
                        continue
                    report["reused"].append(package.name)
                    package_state[package.name] = {
                        "version": package.version,
                        "deb_sha256": deb_sha256,
                        "fingerprint": fingerprint,
                        "output_path": str(candidate),
                        "updated_at": now_utc(),
                    }
                    write_sidecar(candidate, package_state[package.name])
                    persist_progress(
                        state_file=state_file,
                        report_file=report_file,
                        state=state,
                        report=report,
                    )
                    reused_from_sidecar = True
                    break
                if reused_from_sidecar:
                    continue

                reused_from_existing_package = False
                expected_package_name = overrides.get("package_overrides", {}).get(package.name, {}).get("rename", package.name)
                expected_architecture = overrides.get("package_overrides", {}).get(package.name, {}).get("architecture", config["ARCH"])
                for candidate in sidecar_candidates:
                    if not candidate.exists():
                        continue
                    existing_metadata = load_existing_gpkg_metadata(candidate, temp_root=temp_dir)
                    if existing_metadata.get("package") != expected_package_name:
                        continue
                    if existing_metadata.get("version") != package.version:
                        continue
                    if existing_metadata.get("architecture") != expected_architecture:
                        continue
                    report["reused"].append(package.name)
                    package_state[package.name] = {
                        "version": package.version,
                        "deb_sha256": deb_sha256,
                        "fingerprint": fingerprint,
                        "output_path": str(candidate),
                        "updated_at": now_utc(),
                    }
                    write_sidecar(candidate, package_state[package.name])
                    persist_progress(
                        state_file=state_file,
                        report_file=report_file,
                        state=state,
                        report=report,
                    )
                    reused_from_existing_package = True
                    break
                if reused_from_existing_package:
                    continue

            result = convert_deb_to_gpkg(
                deb_path,
                repo_arch_dir=repo_arch_dir,
                overrides=overrides,
                apt_arch=config["APT_ARCH"],
                forced_depends=package.depends,
                include_maintainer_scripts=include_maintainer_scripts,
                include_recommends=include_recommends,
                allow_essential=allow_essential,
                compression_level=zstd_level,
                temp_root=temp_dir,
                verbose=args.verbose,
            )
            report["built"].append(package.name)
            package_state[package.name] = {
                "version": package.version,
                "deb_sha256": deb_sha256,
                "fingerprint": fingerprint,
                "output_path": result["output_path"],
                "updated_at": now_utc(),
            }
            write_sidecar(Path(result["output_path"]), package_state[package.name])
            persist_progress(
                state_file=state_file,
                report_file=report_file,
                state=state,
                report=report,
            )
        except Exception as exc:
            failures[package.name] = str(exc)
            report["failures"][package.name] = str(exc)
            persist_progress(
                state_file=state_file,
                report_file=report_file,
                state=state,
                report=report,
            )

    try:
        indexed_packages = scan_repo(
            repo_arch_dir,
            compression_level=index_zstd_level,
            temp_root=temp_dir,
            verbose=args.verbose,
        )
        report["indexed_count"] = len(indexed_packages)
    except Exception as exc:
        failures["index"] = str(exc)
        report["failures"]["index"] = str(exc)
        report["indexed_count"] = 0

    if upload_enabled:
        try:
            command = build_upload_command(config, repo_root)
            if command is None:
                failures["upload"] = "UPLOAD_ENABLED is true but no upload backend was configured"
                report["failures"]["upload"] = failures["upload"]
            else:
                run(command, verbose=args.verbose)
                report["uploaded"] = True
        except Exception as exc:
            failures["upload"] = str(exc)
            report["failures"]["upload"] = str(exc)

    report["finished_at"] = now_utc()
    report["failures"] = failures
    persist_progress(
        state_file=state_file,
        report_file=report_file,
        state=state,
        report=report,
    )

    print(
        json.dumps(
            {
                "resolved": len(packages),
                "built": len(report["built"]),
                "reused": len(report["reused"]),
                "indexed": report.get("indexed_count", 0),
                "uploaded": report["uploaded"],
                "failures": failures,
            },
            indent=2,
        )
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

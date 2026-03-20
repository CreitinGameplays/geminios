#!/usr/bin/env python3
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import shlex
import subprocess
import tarfile
import tempfile
from pathlib import Path
from typing import Any, Callable


ARCH_MAP = {
    "all": "x86_64",
    "amd64": "x86_64",
    "arm64": "aarch64",
}

DEFAULT_BLOCKLIST = [
    "base-files",
    "base-passwd",
    "bash",
    "debianutils",
    "dpkg",
    "gcc-*",
    "glibc-*",
    "grub*",
    "init",
    "initramfs-tools*",
    "linux-*",
    "libc6",
    "libpam*",
    "libsystemd*",
    "mount",
    "openssh-server",
    "passwd",
    "systemd*",
    "sysvinit*",
    "udev",
    "util-linux",
]

RELATION_RE = re.compile(
    r"^(?P<name>[A-Za-z0-9.+-]+)"
    r"(?::[A-Za-z0-9-]+)?"
    r"(?:\s*\((?P<op><<|<=|=|>=|>>|<|>)\s*(?P<version>[^)]+)\))?$"
)


def run(
    command: list[str],
    *,
    cwd: Path | None = None,
    capture: bool = False,
    check: bool = True,
    verbose: bool = False,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    if verbose:
        print(f"+ {shlex.join(command)}")
    completed = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and completed.returncode != 0:
        detail = ""
        if capture:
            detail = (completed.stderr or completed.stdout or "").strip()
        if not detail:
            detail = f"exit code {completed.returncode}"
        raise RuntimeError(f"Command failed: {shlex.join(command)}: {detail}")
    return completed


def load_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for lineno, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in raw_line:
            raise ValueError(f"{path}:{lineno}: expected KEY=VALUE")
        key, value = raw_line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if value and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        env[key] = value
    return env


def ensure_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open() as handle:
        return json.load(handle)


def write_json(path: Path, payload: Any) -> None:
    ensure_directory(path.parent)
    temp_path = path.with_suffix(path.suffix + ".tmp")
    with temp_path.open("w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temp_path.replace(path)


def hash_file(path: Path, algorithm: str = "sha256") -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def split_top_level(value: str, separator: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    paren_depth = 0
    bracket_depth = 0
    angle_depth = 0

    for char in value:
        if char == "(":
            paren_depth += 1
        elif char == ")" and paren_depth > 0:
            paren_depth -= 1
        elif char == "[":
            bracket_depth += 1
        elif char == "]" and bracket_depth > 0:
            bracket_depth -= 1
        elif char == "<":
            angle_depth += 1
        elif char == ">" and angle_depth > 0:
            angle_depth -= 1

        if (
            char == separator
            and paren_depth == 0
            and bracket_depth == 0
            and angle_depth == 0
        ):
            part = "".join(current).strip()
            if part:
                parts.append(part)
            current = []
            continue

        current.append(char)

    final_part = "".join(current).strip()
    if final_part:
        parts.append(final_part)
    return parts


def parse_control_stanzas(text: str) -> list[dict[str, str]]:
    stanzas: list[dict[str, str]] = []
    current: dict[str, str] = {}
    last_key: str | None = None

    for raw_line in text.splitlines():
        if not raw_line.strip():
            if current:
                stanzas.append(current)
                current = {}
                last_key = None
            continue

        if raw_line[0].isspace():
            if last_key is None:
                continue
            current[last_key] += "\n" + raw_line[1:]
            continue

        key, value = raw_line.split(":", 1)
        current[key] = value.lstrip()
        last_key = key

    if current:
        stanzas.append(current)
    return stanzas


def choose_first_matching_stanza(
    stanzas: list[dict[str, str]],
    package_name: str,
    version: str,
    apt_arch: str,
) -> dict[str, str] | None:
    for stanza in stanzas:
        if stanza.get("Package") != package_name:
            continue
        if stanza.get("Version") != version:
            continue
        arch = stanza.get("Architecture", "")
        if arch in {"all", apt_arch, ""}:
            return stanza
    for stanza in stanzas:
        if stanza.get("Package") == package_name and stanza.get("Version") == version:
            return stanza
    return None


def dependency_applies_to_arch(restriction: str, apt_arch: str) -> bool:
    tokens = [token.strip() for token in restriction.split() if token.strip()]
    positives = {token for token in tokens if not token.startswith("!")}
    negatives = {token[1:] for token in tokens if token.startswith("!")}

    if positives and apt_arch not in positives and "any" not in positives:
        return False
    if apt_arch in negatives or "any" in negatives:
        return False
    return True


def normalize_relation_atom(atom: str, apt_arch: str) -> dict[str, str] | None:
    cleaned = atom.strip()
    if not cleaned:
        return None

    cleaned = re.sub(r"\s*<[^>]+>", "", cleaned).strip()

    arch_match = re.search(r"\[([^\]]+)\]", cleaned)
    if arch_match:
        if not dependency_applies_to_arch(arch_match.group(1), apt_arch):
            return None
        cleaned = (cleaned[: arch_match.start()] + cleaned[arch_match.end() :]).strip()

    match = RELATION_RE.match(cleaned.replace(":any", "").replace(":native", ""))
    if not match:
        return None

    name = match.group("name")
    op = match.group("op")
    version = match.group("version")
    normalized = name if not op else f"{name} ({op} {version.strip()})"
    return {"name": name, "normalized": normalized}


def unique_items(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def matches_any(name: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(name, pattern) for pattern in patterns)


def normalize_dependency_field(
    value: str,
    *,
    package_name: str,
    apt_arch: str,
    dependency_choices: dict[str, str],
    dependency_exists: Callable[[str], bool],
    skip_patterns: list[str],
) -> list[str]:
    dependencies: list[str] = []
    for group in split_top_level(value, ","):
        alternatives = split_top_level(group, "|")
        override_key = f"{package_name}::{group}"
        choice = dependency_choices.get(override_key) or dependency_choices.get(group)
        selected: str | None = None

        if choice:
            parsed = normalize_relation_atom(choice, apt_arch)
            if parsed:
                selected = parsed["normalized"]
        else:
            for alternative in alternatives:
                parsed = normalize_relation_atom(alternative, apt_arch)
                if not parsed:
                    continue
                if matches_any(parsed["name"], skip_patterns):
                    continue
                if dependency_exists(parsed["name"]):
                    selected = parsed["normalized"]
                    break

        if selected is None:
            for alternative in alternatives:
                parsed = normalize_relation_atom(alternative, apt_arch)
                if parsed:
                    selected = parsed["normalized"]
                    break

        if selected:
            dependencies.append(selected)

    return unique_items(dependencies)


def normalize_relation_field(value: str, *, apt_arch: str) -> list[str]:
    relations: list[str] = []
    for group in split_top_level(value, ","):
        for alternative in split_top_level(group, "|"):
            parsed = normalize_relation_atom(alternative, apt_arch)
            if parsed:
                relations.append(parsed["normalized"])
                break
    return unique_items(relations)


def normalize_architecture(debian_arch: str) -> str:
    return ARCH_MAP.get(debian_arch, debian_arch)


def sanitize_section(section: str) -> str:
    top_level = section.split("/", 1)[0].strip().lower() or "misc"
    sanitized = re.sub(r"[^a-z0-9.+-]+", "-", top_level).strip("-")
    return sanitized or "misc"


def safe_filename_component(value: str) -> str:
    return value.replace(":", "%3a").replace("/", "_").replace(" ", "_")


def read_seed_packages(path: Path) -> list[str]:
    packages: list[str] = []
    if not path.exists():
        return packages
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        packages.append(line)
    return packages


def build_gpkg(
    src_dir: Path,
    output_path: Path,
    *,
    compression_level: int,
    verbose: bool = False,
) -> None:
    control_path = src_dir / "control.json"
    root_dir = src_dir / "root"
    data_dir = src_dir / "data"
    scripts_dir = src_dir / "scripts"

    if not control_path.exists():
        raise FileNotFoundError(f"Missing control.json in {src_dir}")

    ensure_directory(output_path.parent)
    ensure_directory(root_dir)

    with tempfile.TemporaryDirectory(prefix="gpkg-build-") as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        data_tar = temp_dir / "data.tar"
        data_tar_zst = temp_dir / "data.tar.zst"
        final_tar = temp_dir / "final.tar"

        if data_dir.exists() and any(data_dir.iterdir()):
            run(
                ["tar", "-cf", str(data_tar), "-C", str(src_dir), "data"],
                verbose=verbose,
            )
        else:
            run(
                ["tar", "-cf", str(data_tar), "-C", str(root_dir), "."],
                verbose=verbose,
            )

        run(
            [
                "zstd",
                "-T0",
                "-f",
                f"-{compression_level}",
                "--quiet",
                str(data_tar),
                "-o",
                str(data_tar_zst),
            ],
            verbose=verbose,
        )

        with tarfile.open(final_tar, "w", format=tarfile.USTAR_FORMAT) as tar:
            tar.add(control_path, arcname="control.json")
            tar.add(data_tar_zst, arcname="data.tar.zst")
            if scripts_dir.exists() and any(scripts_dir.iterdir()):
                tar.add(scripts_dir, arcname="scripts")

        run(
            [
                "zstd",
                "-T0",
                "-f",
                f"-{compression_level}",
                "--quiet",
                str(final_tar),
                "-o",
                str(output_path),
            ],
            verbose=verbose,
        )


def scan_repo(repo_dir: Path, *, compression_level: int, verbose: bool = False) -> list[dict[str, Any]]:
    packages: list[dict[str, Any]] = []
    repo_dir = repo_dir.resolve()
    ensure_directory(repo_dir)

    for gpkg_path in sorted(repo_dir.rglob("*.gpkg")):
        relative_path = gpkg_path.relative_to(repo_dir).as_posix()
        with tempfile.TemporaryDirectory(prefix="gpkg-scan-") as temp_dir_name:
            temp_tar = Path(temp_dir_name) / "package.tar"
            if verbose:
                print(f"Scanning {relative_path}")
            with temp_tar.open("wb") as handle:
                completed = subprocess.run(
                    ["zstd", "-dc", str(gpkg_path)],
                    stdout=handle,
                    stderr=subprocess.PIPE,
                    text=False,
                )
            if completed.returncode != 0:
                error = completed.stderr.decode(errors="replace").strip()
                raise RuntimeError(f"Failed to decompress {gpkg_path}: {error}")

            with tarfile.open(temp_tar, "r") as tar:
                control_handle = tar.extractfile("control.json")
                if control_handle is None:
                    raise RuntimeError(f"{gpkg_path} does not contain control.json")
                metadata = json.load(control_handle)

        metadata["filename"] = relative_path
        metadata["sha512"] = hash_file(gpkg_path, "sha512")
        metadata["size"] = gpkg_path.stat().st_size
        packages.append(metadata)

    index_path = repo_dir / "Packages.json"
    compressed_index = repo_dir / "Packages.json.zst"
    with index_path.open("w") as handle:
        json.dump(packages, handle, indent=2)
        handle.write("\n")
    run(
        [
            "zstd",
            "-T0",
            "-f",
            f"-{compression_level}",
            str(index_path),
            "-o",
            str(compressed_index),
        ],
        verbose=verbose,
    )
    index_path.unlink(missing_ok=True)
    return packages

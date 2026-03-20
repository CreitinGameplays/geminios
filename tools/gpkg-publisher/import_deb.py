#!/usr/bin/env python3
from __future__ import annotations

import argparse
import functools
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from common import (  # noqa: E402
    DEFAULT_BLOCKLIST,
    DEFAULT_SYSTEM_PROVIDES_FILE,
    apt_candidate_version,
    build_provider_resolver,
    build_gpkg,
    ensure_directory,
    legacy_repo_filename_component,
    load_env_file,
    matches_any,
    normalize_architecture,
    normalize_dependency_field,
    normalize_relation_field,
    parse_control_stanzas,
    read_pattern_file,
    read_json,
    run,
    safe_repo_filename_component,
    sanitize_section,
)


def deb_description(fields: dict[str, str]) -> str:
    description = fields.get("Description", "").strip()
    if not description:
        return fields.get("Package", "Imported Debian package")

    lines = description.splitlines()
    summary = lines[0].strip()
    body: list[str] = []
    for line in lines[1:]:
        stripped = line.strip()
        if stripped == ".":
            body.append("")
        else:
            body.append(stripped)
    if not body:
        return summary
    return summary + "\n\n" + "\n".join(body).strip()


@functools.lru_cache(maxsize=4096)
def package_exists_via_apt(package_name: str, *, verbose: bool) -> bool:
    return apt_candidate_version(package_name, verbose=verbose) is not None


def convert_deb_to_gpkg(
    deb_path: Path,
    *,
    repo_arch_dir: Path,
    overrides: dict[str, Any],
    apt_arch: str,
    forced_depends: list[str] | None = None,
    include_maintainer_scripts: bool,
    allow_essential: bool,
    compression_level: int,
    temp_root: Path | None = None,
    verbose: bool = False,
) -> dict[str, Any]:
    deb_path = deb_path.resolve()
    package_overrides = overrides.get("package_overrides", {})
    dependency_choices = overrides.get("dependency_choices", {})
    skip_patterns = list(DEFAULT_BLOCKLIST)
    skip_patterns.extend(overrides.get("skip_packages", []))
    skip_patterns.extend(overrides.get("skip_patterns", []))
    drop_patterns = overrides.get("provided_by_system_patterns", [])
    provider_resolver = build_provider_resolver(
        apt_arch=apt_arch,
        overrides=overrides,
        provider_exists=lambda name: matches_any(name, drop_patterns) or package_exists_via_apt(name, verbose=verbose),
        verbose=verbose,
    )

    if temp_root is not None:
        ensure_directory(temp_root)

    with tempfile.TemporaryDirectory(
        prefix="gpkg-import-",
        dir=str(temp_root) if temp_root is not None else None,
    ) as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        payload_dir = temp_dir / "payload"
        control_dir = temp_dir / "control"
        source_dir = temp_dir / "source"
        root_dir = source_dir / "root"
        scripts_dir = source_dir / "scripts"

        ensure_directory(payload_dir)
        ensure_directory(control_dir)
        ensure_directory(root_dir)

        run(["dpkg-deb", "-x", str(deb_path), str(payload_dir)], verbose=verbose)
        run(["dpkg-deb", "-e", str(deb_path), str(control_dir)], verbose=verbose)

        control_text = (control_dir / "control").read_text()
        stanzas = parse_control_stanzas(control_text)
        if not stanzas:
            raise RuntimeError(f"Could not parse Debian control fields from {deb_path}")
        fields = stanzas[0]

        original_name = fields["Package"]
        if matches_any(original_name, skip_patterns):
            raise RuntimeError(f"{original_name} matched the configured blocklist")
        if fields.get("Essential", "no").lower() == "yes" and not allow_essential:
            raise RuntimeError(f"{original_name} is marked Essential: yes")

        package_override = package_overrides.get(original_name, {})
        if package_override.get("skip"):
            raise RuntimeError(f"{original_name} was skipped by override")

        gpkg_name = package_override.get("rename", original_name)
        section = sanitize_section(package_override.get("section", fields.get("Section", "misc")))
        gpkg_arch = package_override.get(
            "architecture",
            normalize_architecture(fields.get("Architecture", apt_arch)),
        )
        output_path = get_output_path_for_fields(
            fields,
            repo_arch_dir=repo_arch_dir,
            overrides=overrides,
            apt_arch=apt_arch,
        )

        if forced_depends is None:
            depends = normalize_dependency_field(
                ", ".join(
                    value
                    for value in [fields.get("Pre-Depends", ""), fields.get("Depends", "")]
                    if value
                ),
                package_name=original_name,
                apt_arch=apt_arch,
                dependency_choices=dependency_choices,
                dependency_exists=lambda name: package_exists_via_apt(name, verbose=verbose),
                skip_patterns=skip_patterns,
                drop_patterns=drop_patterns,
                provider_resolver=provider_resolver,
            )
        else:
            depends = list(forced_depends)
        depends = [dep for dep in depends if dep not in package_override.get("depends_remove", [])]
        depends.extend(package_override.get("depends_add", []))

        conflicts = normalize_relation_field(fields.get("Conflicts", ""), apt_arch=apt_arch)
        conflicts.extend(package_override.get("conflicts_add", []))

        provides = normalize_relation_field(fields.get("Provides", ""), apt_arch=apt_arch)
        provides.extend(package_override.get("provides_add", []))

        control_json = {
            "package": gpkg_name,
            "version": fields["Version"],
            "architecture": gpkg_arch,
            "maintainer": package_override.get("maintainer", fields.get("Maintainer", "Debian Maintainers")),
            "description": package_override.get("description", deb_description(fields)),
            "depends": sorted(set(depends)),
            "conflicts": sorted(set(conflicts)),
            "provides": sorted(set(provides)),
            "section": section,
            "priority": fields.get("Priority", ""),
            "debian_package": original_name,
            "debian_version": fields["Version"],
            "debian_architecture": fields.get("Architecture", ""),
        }

        with (source_dir / "control.json").open("w") as handle:
            json.dump(control_json, handle, indent=2)
            handle.write("\n")

        shutil.copytree(payload_dir, root_dir, dirs_exist_ok=True, symlinks=True)

        copy_scripts = include_maintainer_scripts or package_override.get("include_maintainer_scripts", False)
        if copy_scripts:
            ensure_directory(scripts_dir)
            script_drops = set(package_override.get("drop_scripts", []))
            for script_name in ["preinst", "postinst", "prerm", "postrm"]:
                if script_name in script_drops:
                    continue
                source_script = control_dir / script_name
                if source_script.exists():
                    shutil.copy2(source_script, scripts_dir / script_name)

        build_gpkg(
            source_dir,
            output_path,
            compression_level=compression_level,
            temp_root=temp_root,
            verbose=verbose,
        )

    return {
        "package": gpkg_name,
        "debian_package": original_name,
        "version": fields["Version"],
        "section": section,
        "architecture": gpkg_arch,
        "output_path": str(output_path),
    }


def get_output_path_for_fields(
    fields: dict[str, str],
    *,
    repo_arch_dir: Path,
    overrides: dict[str, Any],
    apt_arch: str,
    legacy_filename: bool = False,
) -> Path:
    original_name = fields["Package"]
    package_override = overrides.get("package_overrides", {}).get(original_name, {})
    gpkg_name = package_override.get("rename", original_name)
    section = sanitize_section(package_override.get("section", fields.get("Section", "misc")))
    gpkg_arch = package_override.get(
        "architecture",
        normalize_architecture(fields.get("Architecture", apt_arch)),
    )
    if legacy_filename:
        version_for_filename = legacy_repo_filename_component(fields["Version"])
    else:
        version_for_filename = safe_repo_filename_component(fields["Version"])
    output_dir = repo_arch_dir / "pool" / section
    ensure_directory(output_dir)
    return output_dir / f"{gpkg_name}_{version_for_filename}_{gpkg_arch}.gpkg"


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert Debian .deb files into GeminiOS .gpkg packages.")
    parser.add_argument("deb", nargs="+", help="One or more .deb files to import")
    parser.add_argument("--repo-arch-dir", required=True, help="Path to the architecture directory, such as repo/x86_64")
    parser.add_argument("--overrides-file", help="JSON overrides file")
    parser.add_argument("--config", help="Optional env config file; used only for defaults")
    parser.add_argument("--system-provides-file", help="Optional base-system provides file; defaults to build_system/gpkg_system_provides.txt")
    parser.add_argument("--apt-arch", default="amd64", help="APT architecture to use when normalizing dependencies")
    parser.add_argument("--include-maintainer-scripts", action="store_true", help="Copy Debian maintainer scripts into the gpkg")
    parser.add_argument("--allow-essential", action="store_true", help="Allow importing Essential: yes packages")
    parser.add_argument("--zstd-level", type=int, default=10, help="zstd compression level for generated packages")
    parser.add_argument("--temp-dir", help="Directory to use for large temporary files instead of /tmp")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show executed commands")

    args = parser.parse_args()
    config = load_env_file(Path(args.config)) if args.config else {}
    overrides_value = args.overrides_file or config.get("OVERRIDES_FILE", "")
    overrides = {}
    if overrides_value:
        overrides = read_json(Path(overrides_value).expanduser(), {})
    system_provides_value = args.system_provides_file or config.get("SYSTEM_PROVIDES_FILE", str(DEFAULT_SYSTEM_PROVIDES_FILE))
    system_provided_patterns = read_pattern_file(Path(system_provides_value).expanduser())
    extra_system_patterns = overrides.get("provided_by_system_patterns", [])
    overrides["provided_by_system_patterns"] = list(dict.fromkeys(system_provided_patterns + extra_system_patterns))

    try:
        for deb_name in args.deb:
            result = convert_deb_to_gpkg(
                Path(deb_name),
                repo_arch_dir=Path(args.repo_arch_dir),
                overrides=overrides,
                apt_arch=args.apt_arch,
                forced_depends=None,
                include_maintainer_scripts=args.include_maintainer_scripts,
                allow_essential=args.allow_essential,
                compression_level=args.zstd_level,
                temp_root=Path(args.temp_dir).expanduser() if args.temp_dir else None,
                verbose=args.verbose,
            )
            print(json.dumps(result, indent=2))
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

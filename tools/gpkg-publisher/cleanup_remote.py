#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from common import run  # noqa: E402
from publish import load_config  # noqa: E402


def build_rclone_prefix(config: dict[str, str]) -> list[str]:
    rclone_dest = config.get("RCLONE_DEST", "").strip()
    if not rclone_dest:
        raise RuntimeError("RCLONE_DEST is empty in the config file")

    command = ["rclone"]
    rclone_config = config.get("RCLONE_CONFIG", "").strip()
    if rclone_config:
        config_path = Path(rclone_config).expanduser()
        if not config_path.exists():
            raise RuntimeError(f"RCLONE_CONFIG does not exist: {config_path}")
        if not os.access(config_path, os.R_OK):
            raise RuntimeError(f"RCLONE_CONFIG is not readable by the current user: {config_path}")
        command.extend(["--config", rclone_config])

    extra_args = config.get("RCLONE_EXTRA_ARGS", "").strip()
    if extra_args:
        command.extend(shlex.split(extra_args))

    return command


def delete_matches(
    *,
    prefix: list[str],
    remote: str,
    include_patterns: list[str],
    dry_run: bool,
    verbose: bool,
) -> None:
    command = prefix + ["delete", remote]
    for pattern in include_patterns:
        command.extend(["--include", pattern])
    if dry_run:
        command.append("--dry-run")
    run(command, verbose=verbose)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Remove stale legacy-encoded gpkg files and remote build sidecars from the configured upload target."
    )
    parser.add_argument("--config", default=str(SCRIPT_DIR / "config.env"), help="Path to the publisher env file")
    parser.add_argument("--dry-run", action="store_true", help="Print/delete via rclone dry-run only")
    parser.add_argument("--skip-build-sidecars", action="store_true", help="Do not delete remote *.gpkg.build.json sidecars")
    parser.add_argument("--skip-legacy-encoded", action="store_true", help="Do not delete remote files whose names still contain %3a")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show executed commands")
    args = parser.parse_args()

    config = load_config(Path(args.config))
    remote = config.get("RCLONE_DEST", "").strip()
    prefix = build_rclone_prefix(config)

    if not args.skip_build_sidecars:
        delete_matches(
            prefix=prefix,
            remote=remote,
            include_patterns=["**/*.gpkg.build.json"],
            dry_run=args.dry_run,
            verbose=args.verbose,
        )

    if not args.skip_legacy_encoded:
        delete_matches(
            prefix=prefix,
            remote=remote,
            include_patterns=[
                "**/*%3a*.gpkg",
                "**/*%3A*.gpkg",
                "**/*%3a*.gpkg.build.json",
                "**/*%3A*.gpkg.build.json",
            ],
            dry_run=args.dry_run,
            verbose=args.verbose,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

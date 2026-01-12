# gpkg-worker Implementation Checklist

## Core Objectives
Implement a low-level package worker binary (`gpkg-worker`) that handles the actual file system operations for package installation and removal, mimicking `dpkg`'s safety mechanisms.

## Architecture & Setup
- [x] Create project structure for `gpkg-worker` (likely in `packages/system/gpkg-worker/` or integrated into `gpkg` source tree).
- [x] Define the interface/arguments for `gpkg-worker` (e.g., `--install <package_file>`, `--remove <package_name>`).
- [x] Establish the "database" location (e.g., `/var/lib/gpkg/info/` or similar) for tracking file ownership.

## Installation Logic (`--install`)
- [x] Implement package unpacking logic (extract files to correct destinations).
- [x] **Critical**: During unpacking, record *every* file and directory created into a `.list` file (e.g., `/var/lib/gpkg/info/<pkg>.list`).
    - [x] Ensure directories are recorded.
    - [x] Ensure files are recorded.
- [ ] Implement conflict detection (optional for v1, but good to have: check if file exists and is owned by another package).

## Removal Logic (`--remove`)
- [x] Implement `.list` file parsing.
- [x] Implement Reverse Order Traversal:
    - [x] Read the `.list` file.
    - [x] Process entries from bottom to top (deepest first).
- [x] **File Removal**:
    - [x] If entry is a file: `unlink()`/`remove()`.
- [x] **Directory Safety Mechanism**:
    - [x] If entry is a directory: Attempt `rmdir()`.
    - [x] **Catch Error**: If `rmdir` fails with `ENOTEMPTY` (or equivalent), **ignore it and proceed**. This is the safety rail.
    - [x] Only fail if `rmdir` fails for other reasons (e.g., permission denied, though usually run as root).

## Database Management
- [x] Clean up `.list` files after successful removal.
- [x] Handle updates (Install new -> Remove old? Or direct overwrite? - For `gpkg-worker`, assume atomic operations or follow `dpkg` flow).

## Testing & Safety Rails
- [x] Create a "shared directory" test case (e.g., installing a package that owns `/usr/bin/mytool`).
    - [x] Verify `remove` deletes `/usr/bin/mytool`.
    - [x] Verify `remove` **does not** delete `/usr/bin`.
- [x] Create an "exclusive directory" test case (e.g., `/usr/lib/mypkg/plugin.so`).
    - [x] Verify `remove` deletes `plugin.so`.
    - [x] Verify `remove` deletes `/usr/lib/mypkg/` (since it becomes empty).
    - [x] Verify `remove` preserves `/usr/lib`.

## Maintainer Scripts (Future/Optional)
- [x] (Placeholder) Support `preinst`, `postinst`, `prerm`, `postrm` execution.

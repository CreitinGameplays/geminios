# GPKG v3 Implementation Plan - "The Ecosystem Era"

Goal: Evolve `gpkg` from a package extractor into a full transaction manager capable of handling complex Desktop Environments (XFCE4, GNOME) and system upgrades autonomously.

## 1. Core Transaction Management
- [x] **Transaction Hooks / Triggers (Critical)**
    - Implement a system to queue triggers during package installation.
    - Execute triggers ONCE at the end of the transaction.
    - Triggers needed:
        - `glib-compile-schemas` (for `/usr/share/glib-2.0/schemas`)
        - `gtk-update-icon-cache` (for `/usr/share/icons/*`)
        - `update-mime-database` (for `/usr/share/mime`)
        - `update-desktop-database` (for `/usr/share/applications`)
        - `fc-cache` (for fonts)
        - `ldconfig` (for shared libraries)
- [x] **Two-Phase Installation (Download-Install)**
    - Phase 1: Resolve all dependencies and download ALL `.gpkg` files to cache. Verify hashes.
    - Phase 2: If all downloads succeed, begin installation loop.
    - Prevents broken partial installs due to network failure.
- [x] **Locking Mechanism**
    - Create `/var/lib/gpkg/lock` to prevent multiple instances of `gpkg` running simultaneously.

## 2. Advanced Dependency Resolution
- [x] **Virtual Packages (`Provides`)**
    - Support packages that "provide" a virtual capability (e.g., `xfwm4` provides `x-window-manager`).
    - Resolve dependencies via `provides` if exact name match fails.
- [x] **Version Constraints**
    - Parse comparisons: `libgtk (>= 3.24)`, `(<< 2.0)`, `(= 1.0)`.
    - Fail resolution if constraints are not met.
- [x] **Conflict Resolution**
    - Support `conflicts` field in `control.json`.
    - Refuse to install if a conflicting package is present (or offer to remove it).

## 3. Preservation & Safety
- [x] **File Conflict Detection**
    - Before extracting, check if any file in the payload exists and belongs to *another* package.
    - Abort if conflict detected (force option available).
- [x] **Configuration Protection (`.pacnew`)**
    - Identify configuration files (in `/etc`).
    - If modifying an existing file with different content, install the new version as `.pacnew` instead of overwriting.
- [x] **Protected System Directories**
    - Prevent removal of critical system directories (e.g., `/usr`, `/bin`) even if they become empty during package removal.

## 4. UI/UX Improvements
- [x] **Detailed Progress Bars**
    - Show "Downloading (3/10)..."
    - Show "Installing (3/10)..."
- [ ] **Colorized & structured output**
    - Warning/Error highlights. 
    - Transaction summary (Pkgs to add: 5, Pkgs to remove: 1, Download size: 50MB).

## 5. Development & Testing Tools
- [ ] **`gpkg-verify`**
    - Scan installed packages against their checksums/file lists to detect corruption.
- [ ] **Test Suites**
    - Create mock repositories to test dependency resolution logic without hitting the network.

[x] Add a robust `--purge` argument so it will remove the package and also ALL its dependencies it installed together to gpkg
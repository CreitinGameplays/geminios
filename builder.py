#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import json
import shutil
import glob
import re
import tempfile
from datetime import datetime, timezone

# Terminal Colors
class Colors:
    """ANSI color codes for terminal output"""
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    
    # Regular colors
    RED = "\033[91m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    MAGENTA = "\033[95m"
    CYAN = "\033[96m"
    WHITE = "\033[97m"
    
    # Background colors
    BG_RED = "\033[41m"
    BG_GREEN = "\033[42m"
    BG_YELLOW = "\033[43m"

def color(text, color_code):
    """Wrap text with color code"""
    return f"{color_code}{text}{Colors.RESET}"

def print_success(msg):
    """Print success message in green"""
    print(color(msg, Colors.GREEN))

def print_error(msg):
    """Print error message in red"""
    print(color(msg, Colors.RED))

def print_warning(msg):
    """Print warning message in yellow"""
    print(color(msg, Colors.YELLOW))

def print_info(msg):
    """Print info message in cyan"""
    print(color(msg, Colors.CYAN))

def print_section(msg):
    """Print section header in magenta bold"""
    print(color(msg, Colors.BOLD + Colors.MAGENTA))

def print_status(msg):
    """Print status message in blue"""
    print(color(msg, Colors.BLUE))

# Configuration
ROOT_DIR = os.getcwd()
BUILD_SYSTEM_DIR = os.path.join(ROOT_DIR, "build_system")
PORTS_DIR = os.path.join(ROOT_DIR, "ports")
LOG_DIR = os.path.join(ROOT_DIR, "logs")
ENV_CONFIG = os.path.join(BUILD_SYSTEM_DIR, "env_config.sh")
MANIFEST_FILE = os.path.join(BUILD_SYSTEM_DIR, "package_manifests.json")
VERIFY_SOURCES_SCRIPT = os.path.join(ROOT_DIR, "tools", "verify_source_urls.py")
SYS_INFO_HEADER = os.path.join(ROOT_DIR, "src", "sys_info.h")
GPKG_UPGRADE_COMPANIONS_FILE = os.environ.get(
    "GPKG_UPGRADE_COMPANIONS_FILE",
    os.path.join(BUILD_SYSTEM_DIR, "gpkg_upgrade_companions.conf"),
)
GPKG_DEBIAN_CONFIG_FILE = os.environ.get(
    "GPKG_DEBIAN_CONFIG_FILE",
    os.path.join(BUILD_SYSTEM_DIR, "gpkg_debian.conf"),
)
GPKG_IMPORT_POLICY_FILE = os.environ.get(
    "GPKG_IMPORT_POLICY_FILE",
    os.path.join(BUILD_SYSTEM_DIR, "gpkg_import_policy.json"),
)
GPKG_DEFAULT_SOURCES_FILE = os.environ.get(
    "GPKG_DEFAULT_SOURCES_FILE",
    os.path.join(BUILD_SYSTEM_DIR, "gpkg_default_sources.list"),
)
HOST_DEV_OVERLAY_FILE = os.path.join(ROOT_DIR, ".host_dev_overlay_paths.json")

# Load Manifests
try:
    with open(MANIFEST_FILE, "r") as f:
        PACKAGE_MANIFESTS = json.load(f)
except FileNotFoundError:
    print_warning("WARNING: Package manifests file not found. Verification will be limited.")
    PACKAGE_MANIFESTS = {}

# Order of builds
PACKAGES = [
    # Core System Foundation
    "kernel_headers",
    "glibc",
    "libxcrypt",
    "zlib",
    "openssl",
    "ca-certificates",
    "libffi",
    "ncurses",
    "expat",
    "curl",
    "zstd",
    "xz",
    "pkg-config",
    "bison",
    "flex",
    "python",
    "setuptools",
    "markupsafe",
    "mako",
    "jinja2",
    "meson",
    "ninja",
    "gperf",
    "gettext",
    "perl",
    "texinfo",
    "linux-pam",
    "libcap",
    "util-macros",
    "elfutils",
    "pcre2",
    "e2fsprogs",
    "util-linux",
    "libxml2",
    "dbus",
    "glib",
    "json-glib",
    "gobject-introspection",
    # X11 Foundation
    "xorgproto",
    "libxau",
    "libxdmcp",
    "xcb-proto",
    "libpthread-stubs",
    "libxcb",
    "xtrans",
    "xcb-util",
    "xcb-util-keysyms",
    # X11 Client Libraries
    "libx11",
    "libxext",
    "libxfixes",
    "libxrender",
    "libxdamage",
    "libxcomposite",
    "libxcursor",
    "libxi",
    "libxrandr",
    "libxinerama",
    "libxtst",
    "libxxf86vm",
    "libXres",
    "libxpm",
    # Graphics Libraries
    "libpng",
    "libjpeg-turbo",
    "tiff",
    "freetype",
    "fontconfig",
    "pixman",
    "libxft",
    "libice",
    "libsm",
    "libxt",
    "libxmu",
    "libxaw",
    "libxkbfile",
    "libfontenc",
    "libxfont2",
    "xkbcomp",
    "libpciaccess",
    "pciutils",
    "libxshmfence",
    "font-util",
    "system-fonts",
    "eudev",
    "elogind",
    # Wayland Foundation
    "wayland-protocols",
    "wayland",
    "libdrm",
    "libglvnd",
    "mesa",
    # GTK Stack & Rendering
    "cairo",
    "harfbuzz",
    "fribidi",
    "pango",
    "shared-mime-info",
    "gdk-pixbuf",
    "atk",
    "at-spi2-core",
    "at-spi2-atk",
    "libepoxy",
    "libxkbcommon",
    "gsettings-desktop-schemas",
    "hicolor-icon-theme",
    "adwaita-icon-theme",
    "gtk3",
    "startup-notification",
    "libwnck",
    "dconf",
    "xdg-user-dirs",
    # X Server & Drivers
    "xorg-server",
    "xf86-video-fbdev",
    "libevdev",
    "mtdev",
    "libinput",
    "xf86-input-evdev",
    "xkeyboard-config",
    "setxkbmap",
    "xinit",
    "xterm",
    "xprop",
    # User Utilities
    "bash",
    "coreutils",
    "tar",
    "gzip",
    "findutils",
    "diffutils",
    "patch",
    "which",
    "procps-ng",
    "nano",
    "grep",
    "sed",
    "gawk",
    "kbd",
    "grub",
    # Development Tools
    "binutils",
    "gcc",
    "git",
    # GeminiOS Specifics
    "geminios_core", # init, signals, user_mgmt
    "geminios_pkgs", # ls, pwd, cat, etc.
    "geminios_complex" # gpkg, ping, installer, etc.
]

PACKAGE_DEPENDENCIES = {
    "ca-certificates": [],
    "curl": ["zlib", "openssl", "ca-certificates"],
    "git": ["zlib", "openssl", "expat", "curl", "ca-certificates"],
    "linux-pam": ["libxcrypt", "meson", "ninja", "pkg-config"],
    "jinja2": ["python", "setuptools", "markupsafe"],
    "elogind": ["dbus", "eudev", "linux-pam", "libcap", "jinja2", "gperf", "meson", "ninja", "pkg-config"],
    "wayland-protocols": ["python", "meson", "ninja", "pkg-config"],
    "wayland": ["expat", "libffi", "pkg-config", "meson", "ninja", "wayland-protocols"],
    "json-glib": ["glib", "meson", "ninja", "pkg-config"],
    "libxkbcommon": [
        "wayland",
        "xkeyboard-config",
        "libxcb",
        "xcb-util-keysyms",
        "pkg-config",
        "meson",
        "ninja",
    ],
    "dconf": ["dbus", "glib", "json-glib", "meson", "ninja", "pkg-config"],
    "xdg-user-dirs": ["glib", "gettext", "pkg-config"],
    "gtk3": [
        "dbus",
        "glib",
        "gobject-introspection",
        "cairo",
        "pango",
        "gdk-pixbuf",
        "atk",
        "at-spi2-core",
        "at-spi2-atk",
        "libepoxy",
        "libxkbcommon",
        "wayland-protocols",
        "wayland",
        "shared-mime-info",
        "gsettings-desktop-schemas",
        "hicolor-icon-theme",
        "adwaita-icon-theme",
    ],
    "libinput": [
        "eudev",
        "libevdev",
        "mtdev",
        "pkg-config",
        "meson",
        "ninja",
    ],
    "geminios_core": ["kernel_headers", "glibc", "dbus", "eudev", "linux-pam", "elogind"],
    "geminios_complex": ["kernel_headers", "glibc", "geminios_core"],
}

def resolve_requested_packages(requested_packages):
    """Resolve requested packages and their dependencies in build order."""
    needed = set()
    visiting = set()

    def visit(pkg_name):
        if pkg_name in needed:
            return
        if pkg_name in visiting:
            raise ValueError(f"Circular dependency detected at '{pkg_name}'")
        if pkg_name not in PACKAGES:
            raise ValueError(f"Unknown package '{pkg_name}'")

        visiting.add(pkg_name)
        for dep_name in PACKAGE_DEPENDENCIES.get(pkg_name, []):
            visit(dep_name)
        visiting.remove(pkg_name)
        needed.add(pkg_name)

    for pkg_name in requested_packages:
        visit(pkg_name)

    return [pkg_name for pkg_name in PACKAGES if pkg_name in needed]

def load_os_identity():
    """Reads GeminiOS identity macros from src/sys_info.h."""
    identity = {
        "OS_NAME": "GeminiOS",
        "OS_VERSION": "Rolling",
        "OS_VERSION_ID": "rolling",
        "OS_RELEASE_TRACK": "rolling",
        "OS_CODENAME": "Castor",
        "OS_ARCH": "x86_64",
        "OS_ID": "geminios",
        "OS_ID_LIKE": "debian",
        "OS_ANSI_COLOR": "0;34",
    }

    define_re = re.compile(r'^\s*#define\s+([A-Z0-9_]+)\s+"([^"]*)"\s*$')
    if not os.path.exists(SYS_INFO_HEADER):
        return identity

    with open(SYS_INFO_HEADER, "r") as f:
        for line in f:
            match = define_re.match(line)
            if match:
                identity[match.group(1)] = match.group(2)

    return identity


def slugify_release_token(value):
    slug = re.sub(r"[^a-z0-9]+", "-", value.strip().lower()).strip("-")
    return slug or "rolling"


def get_geminios_release_info():
    """Builds rolling-release identity and snapshot metadata."""
    identity = load_os_identity()
    now = datetime.now(timezone.utc)
    snapshot_date = now.strftime("%Y.%m.%d")
    snapshot_compact = now.strftime("%Y%m%d")
    build_id = now.strftime("%Y%m%d.%H%M")
    build_slug = build_id.replace(".", "-")
    codename_slug = slugify_release_token(identity["OS_CODENAME"])
    display_version = f'{identity["OS_VERSION"]} {snapshot_date}'

    return {
        "name": identity["OS_NAME"],
        "id": identity["OS_ID"],
        "id_like": identity["OS_ID_LIKE"],
        "ansi_color": identity["OS_ANSI_COLOR"],
        "codename": identity["OS_CODENAME"],
        "track": identity["OS_RELEASE_TRACK"],
        "version_label": identity["OS_VERSION"],
        "version_id": identity["OS_VERSION_ID"],
        "display_version": display_version,
        "pretty_name": f'{identity["OS_NAME"]} {display_version}',
        "snapshot_date": snapshot_date,
        "snapshot_compact": snapshot_compact,
        "build_id": build_id,
        "image_id": f'{identity["OS_ID"]}-{codename_slug}',
        "iso_name": f'{identity["OS_NAME"]}-{codename_slug}-{identity["OS_VERSION_ID"]}-{build_slug}.iso',
    }

def run_command(cmd, cwd=None, log_file=None, use_target_env=False, debug=False):
    """Runs a shell command and captures output to log"""
    # Use target environment only if requested
    target_env_script = os.path.join(BUILD_SYSTEM_DIR, 'target_env.sh')
    target_env = f"source {target_env_script} && " if use_target_env else ""
    
    # We source env_config.sh and then the command (or script).
    # We use ( source script ) in a subshell so 'exit' or 'set -e' 
    # doesn't kill the main builder loop but still inherits functions.
    
    # Check if cmd is a script path
    if cmd.endswith(".sh") and os.path.exists(cmd):
        cmd_to_run = f"( source {cmd} )"
    else:
        cmd_to_run = cmd

    # We unset problematic variables ALWAYS to ensure a clean start,
    # then the source command will set them if needed for the target.
    clean_env = "unset LD_LIBRARY_PATH PYTHONHOME PYTHONPATH && "
    debug_env = "export ENABLE_DEBUG=true && " if debug else "export ENABLE_DEBUG=false && "
    full_cmd = f"{clean_env}{debug_env}source {ENV_CONFIG} && {target_env}{cmd_to_run}"
    
    if log_file:
        with open(log_file, "a") as f:
            f.write(f"\n--- Executing: {cmd} ---\n")
            process = subprocess.Popen(full_cmd, shell=True, executable="/usr/bin/bash", cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
            process.wait()
    else:
        process = subprocess.Popen(full_cmd, shell=True, executable="/usr/bin/bash", cwd=cwd)
        process.wait()
        
    return process.returncode

def is_built(pkg_name):
    """Checks if a package is already built and installed correctly"""
    if pkg_name not in PACKAGE_MANIFESTS:
        return False
    return not get_package_verification_issues(pkg_name)

def expand_manifest_artifact_paths(artifact):
    """Return candidate paths for a manifest artifact, supporting exact paths and globs."""
    project_relative = artifact.lstrip("/") if artifact.startswith("/") else artifact
    rootfs_pattern = os.path.join(ROOT_DIR, "rootfs", project_relative)
    project_pattern = os.path.join(ROOT_DIR, artifact)

    patterns = [rootfs_pattern]
    if not artifact.startswith("/"):
        patterns.append(project_pattern)

    matched = []
    for pattern in patterns:
        if any(ch in pattern for ch in "*?["):
            matched.extend(glob.glob(pattern))
        else:
            matched.append(pattern)
    return matched

def fallback_manifest_artifact_paths(artifact):
    """Return smart fallback candidates for manifest entries that describe shared libraries."""
    project_relative = artifact.lstrip("/") if artifact.startswith("/") else artifact
    rootfs_path = os.path.join(ROOT_DIR, "rootfs", project_relative)
    dirname = os.path.dirname(rootfs_path)
    basename = os.path.basename(rootfs_path)

    if not os.path.isdir(dirname):
        return []

    fallback = []

    # Treat linker-name expectations like libfoo.so as satisfied by a versioned runtime
    # library such as libfoo.so.4 when the build intentionally omits the dev symlink.
    if basename.endswith(".so"):
        pattern = os.path.join(dirname, basename + ".*")
        fallback.extend(glob.glob(pattern))

    # If a glob like libpython3.11.so* is used, also accept the canonical versioned
    # runtime soname if glob expansion happened before the file was staged.
    if basename.endswith(".so*"):
        pattern = os.path.join(dirname, basename[:-1] + ".*")
        fallback.extend(glob.glob(pattern))

    seen = set()
    unique = []
    for path in fallback:
        if path in seen:
            continue
        seen.add(path)
        unique.append(path)
    return unique

def artifact_exists_from_manifest(artifact):
    """Check whether a manifest artifact exists, allowing glob patterns."""
    matched_paths = expand_manifest_artifact_paths(artifact)
    if not matched_paths:
        matched_paths = fallback_manifest_artifact_paths(artifact)
    if not matched_paths:
        return False

    for path in matched_paths:
        if os.path.exists(path):
            return True
    return False

def get_missing_manifest_artifacts(pkg_name):
    """Return missing manifest entries for a package."""
    if pkg_name not in PACKAGE_MANIFESTS:
        return []

    missing_artifacts = []
    for artifact in PACKAGE_MANIFESTS[pkg_name]:
        if not artifact_exists_from_manifest(artifact):
            missing_artifacts.append(artifact)
    return missing_artifacts

def get_dbus_runtime_abi_issues():
    """Return DBus runtime/library ABI mismatches inside the staged rootfs."""
    dbus_launch_path = os.path.join(ROOT_DIR, "rootfs", "usr", "bin", "dbus-launch")
    dbus_lib_path = os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "x86_64-linux-gnu", "libdbus-1.so.3")

    if not (os.path.exists(dbus_launch_path) and os.path.exists(dbus_lib_path)):
        return []

    def extract_dbus_private_versions(path):
        result = subprocess.run(
            ["objdump", "-T", path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return None, result.stderr.strip()

        versions = set(re.findall(r"LIBDBUS_PRIVATE_[A-Za-z0-9_.-]+", result.stdout))
        return versions, None

    required_versions, required_error = extract_dbus_private_versions(dbus_launch_path)
    provided_versions, provided_error = extract_dbus_private_versions(dbus_lib_path)

    issues = []
    if required_error:
        issues.append(f"could not inspect dbus-launch private ABI: {required_error}")
        return issues
    if provided_error:
        issues.append(f"could not inspect libdbus private ABI: {provided_error}")
        return issues

    missing_versions = sorted(required_versions - provided_versions)
    if missing_versions:
        issues.append(
            "dbus-launch expects private DBus symbols that the image library does not provide: "
            + ", ".join(missing_versions)
        )
    return issues

def load_host_dev_overlay_paths():
    """Load the recorded set of host-dev-overlay paths inside rootfs."""
    if not os.path.exists(HOST_DEV_OVERLAY_FILE):
        return set()

    try:
        with open(HOST_DEV_OVERLAY_FILE, "r") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return set()

    if not isinstance(data, list):
        return set()

    return {str(path) for path in data if isinstance(path, str)}

def save_host_dev_overlay_paths(paths):
    """Persist the recorded set of host-dev-overlay paths inside rootfs."""
    with open(HOST_DEV_OVERLAY_FILE, "w") as f:
        json.dump(sorted(set(paths)), f, indent=2)
        f.write("\n")

def collect_missing_runtime_deps(rootfs_dir, start_paths):
    """Return recursive DT_NEEDED dependencies that are missing from the staged rootfs."""
    issues = []
    visited = set()
    to_process = [path for path in start_paths if os.path.exists(path)]

    while to_process:
        current = os.path.realpath(to_process.pop())
        if current in visited:
            continue
        visited.add(current)

        for lib_filename in get_elf_needed(current):
            candidate = find_rootfs_library(rootfs_dir, lib_filename)
            if not candidate:
                current_rel = os.path.relpath(current, rootfs_dir).replace(os.sep, "/")
                issues.append(f"{current_rel} is missing runtime dependency {lib_filename}")
                continue
            to_process.append(candidate)

    return issues

def get_glib_runtime_issues():
    """Return GLib/GIO runtime mismatches inside the staged rootfs."""
    rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
    libgio_path = os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu", "libgio-2.0.so.0")
    if not os.path.exists(libgio_path):
        return []

    issues = []
    libgio_real = os.path.realpath(libgio_path)
    libgio_needed = set(get_elf_needed(libgio_real))
    unexpected_deps = sorted({"libmount.so.1", "libselinux.so.1", "libsepol.so.2"} & libgio_needed)
    if unexpected_deps:
        issues.append(
            "libgio unexpectedly links against disabled runtime libraries: "
            + ", ".join(unexpected_deps)
        )

    issues.extend(
        collect_missing_runtime_deps(
            rootfs_dir,
            [
                os.path.join(rootfs_dir, "usr", "bin", "glib-compile-schemas"),
                libgio_real,
            ],
        )
    )
    return issues

def get_libxml2_runtime_issues():
    """Return libxml2 runtime mismatches inside the staged rootfs."""
    rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
    libxml2_path = os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu", "libxml2.so")
    if not os.path.exists(libxml2_path):
        return []

    issues = []
    libxml2_real = os.path.realpath(libxml2_path)
    expected_basename = "libxml2.so.2.12.4"
    if os.path.basename(libxml2_real) != expected_basename:
        issues.append(
            f"libxml2 runtime is {os.path.basename(libxml2_real)}, expected {expected_basename}"
        )

    issues.extend(
        collect_missing_runtime_deps(
            rootfs_dir,
            [
                os.path.join(rootfs_dir, "usr", "bin", "update-mime-database"),
                libxml2_real,
            ],
        )
    )
    return issues

def get_shared_mime_info_runtime_issues():
    """Return shared-mime-info runtime mismatches inside the staged rootfs."""
    rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
    update_mime_path = os.path.join(rootfs_dir, "usr", "bin", "update-mime-database")
    if not os.path.exists(update_mime_path):
        return []

    return collect_missing_runtime_deps(rootfs_dir, [update_mime_path])

def get_util_linux_runtime_issues():
    """Return util-linux ABI/runtime mismatches inside the staged rootfs."""
    rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
    libmount_path = os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu", "libmount.so.1")
    if not os.path.exists(libmount_path):
        return []

    issues = []
    libmount_real = os.path.realpath(libmount_path)
    libmount_needed = set(get_elf_needed(libmount_real))
    unexpected_selinux_deps = sorted({"libselinux.so.1", "libsepol.so.2"} & libmount_needed)
    if unexpected_selinux_deps:
        issues.append(
            "libmount unexpectedly links against SELinux runtime libraries: "
            + ", ".join(unexpected_selinux_deps)
        )
    issues.extend(
        collect_missing_runtime_deps(
            rootfs_dir,
            [
                os.path.join(rootfs_dir, "bin", "mount"),
                os.path.join(rootfs_dir, "bin", "umount"),
                os.path.join(rootfs_dir, "sbin", "switch_root"),
                libmount_real,
            ],
        )
    )
    return issues

def get_package_verification_issues(pkg_name):
    """Return manifest and semantic verification issues for a package."""
    issues = []
    issues.extend(f"missing artifact: {artifact}" for artifact in get_missing_manifest_artifacts(pkg_name))

    if pkg_name == "dbus":
        issues.extend(get_dbus_runtime_abi_issues())
    elif pkg_name == "glib":
        issues.extend(get_glib_runtime_issues())
    elif pkg_name == "libxml2":
        issues.extend(get_libxml2_runtime_issues())
    elif pkg_name == "shared-mime-info":
        issues.extend(get_shared_mime_info_runtime_issues())
    elif pkg_name == "util-linux":
        issues.extend(get_util_linux_runtime_issues())

    return issues

def remove_path(path):
    """Remove a file, symlink, or directory tree if it exists."""
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.unlink(path)

def resolve_rootfs_copy_destination(dest_path):
    """Follow an existing rootfs symlink destination so host overlay copies land on the canonical path."""
    if os.path.islink(dest_path):
        target_path = os.path.realpath(dest_path)
        rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
        try:
            common_root = os.path.commonpath([rootfs_dir, target_path])
        except ValueError:
            common_root = ""
        if common_root == rootfs_dir:
            return target_path
    return dest_path

def merge_rootfs_entry(source_path, dest_path):
    """Move a rootfs entry into place, merging directories when needed."""
    if os.path.isdir(source_path) and not os.path.islink(source_path):
        if os.path.lexists(dest_path) and not (os.path.isdir(dest_path) and not os.path.islink(dest_path)):
            remove_path(dest_path)
        os.makedirs(dest_path, exist_ok=True)
        moved_count = 0
        for entry in sorted(os.listdir(source_path)):
            moved_count += merge_rootfs_entry(
                os.path.join(source_path, entry),
                os.path.join(dest_path, entry),
            )
        if os.path.isdir(source_path) and not os.listdir(source_path):
            os.rmdir(source_path)
        return moved_count

    if os.path.lexists(dest_path):
        remove_path(dest_path)
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    shutil.move(source_path, dest_path)
    return 1

def normalize_rootfs_multiarch_layout(report=False):
    """Fold legacy lib64 installs back into the canonical Debian multiarch layout."""
    migration_specs = [
        (
            os.path.join(ROOT_DIR, "rootfs", "lib64"),
            os.path.join(ROOT_DIR, "rootfs", "lib", "x86_64-linux-gnu"),
            {"x86_64-linux-gnu"},
        ),
        (
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib64"),
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "x86_64-linux-gnu"),
            {"x86_64-linux-gnu"},
        ),
        (
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "pkgconfig"),
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "x86_64-linux-gnu", "pkgconfig"),
            set(),
        ),
    ]

    migrated_entries = []
    for legacy_dir, canonical_dir, reserved_entries in migration_specs:
        if os.path.islink(legacy_dir) or not os.path.isdir(legacy_dir):
            continue

        os.makedirs(canonical_dir, exist_ok=True)
        for entry in sorted(os.listdir(legacy_dir)):
            if entry in reserved_entries:
                continue
            source_path = os.path.join(legacy_dir, entry)
            dest_path = os.path.join(canonical_dir, entry)
            merge_rootfs_entry(source_path, dest_path)
            migrated_entries.append((source_path, dest_path))

    if report and migrated_entries:
        print_info("[*] Normalizing staged library layout back to Debian multiarch...")
        for source_path, dest_path in migrated_entries:
            print_info(f"  Migrated {source_path} -> {dest_path}")

    normalize_rootfs_usr_lib_top_level(report=report)
    ensure_multiarch_dev_compat(report=report)
    return migrated_entries

def normalize_rootfs_usr_lib_top_level(report=False):
    """Relocate top-level /usr/lib libraries into the canonical multiarch directory."""
    usr_lib_dir = os.path.join(ROOT_DIR, "rootfs", "usr", "lib")
    canonical_dir = os.path.join(usr_lib_dir, "x86_64-linux-gnu")
    if not os.path.isdir(usr_lib_dir):
        return []

    os.makedirs(canonical_dir, exist_ok=True)

    manifest_owned_artifacts = set()
    for artifacts in PACKAGE_MANIFESTS.values():
        for artifact in artifacts:
            if any(ch in artifact for ch in "*?["):
                continue
            manifest_owned_artifacts.add(artifact.lstrip("/"))

    relocated_entries = []

    def library_family_prefix(name):
        if ".so" in name:
            return name.split(".so", 1)[0] + ".so"
        if name.endswith(".a"):
            return name[:-2]
        return name

    def is_linker_name(name):
        return name.endswith(".so") or name.endswith(".a")

    def is_soname_link(name):
        return re.search(r"\.so\.\d+$", name) is not None

    def preferred_family_target(family_matches):
        exact_versions = [name for name in family_matches if re.search(r"\.so\.\d+\.", name)]
        if exact_versions:
            return sorted(exact_versions)[-1]
        return sorted(family_matches)[-1] if family_matches else None

    candidate_entries = [
        entry for entry in sorted(os.listdir(usr_lib_dir))
        if (
            (entry.startswith("lib") or entry == "preloadable_libintl.so")
            and not (os.path.isdir(os.path.join(usr_lib_dir, entry)) and not os.path.islink(os.path.join(usr_lib_dir, entry)))
        )
    ]

    for entry in candidate_entries:
        source_path = os.path.join(usr_lib_dir, entry)
        rel_path = os.path.relpath(source_path, os.path.join(ROOT_DIR, "rootfs")).replace(os.sep, "/")
        canonical_path = os.path.join(canonical_dir, entry)
        family_prefix = library_family_prefix(entry)
        canonical_family_matches = sorted(
            candidate for candidate in os.listdir(canonical_dir)
            if candidate != entry and library_family_prefix(candidate) == family_prefix
        )
        family_target = preferred_family_target(canonical_family_matches)

        if os.path.islink(source_path):
            if not os.path.lexists(canonical_path):
                source_target = os.readlink(source_path)
                target_basename = os.path.basename(source_target)
                if os.path.lexists(os.path.join(canonical_dir, target_basename)):
                    os.symlink(target_basename, canonical_path)
                elif family_target:
                    os.symlink(family_target, canonical_path)
            remove_path(source_path)
            relocated_entries.append((source_path, canonical_path, "removed-compat"))
            continue

        if os.path.lexists(canonical_path):
            remove_path(source_path)
            relocated_entries.append((source_path, canonical_path, "removed-compat"))
            continue

        if (
            family_target
            and rel_path not in manifest_owned_artifacts
            and not is_linker_name(entry)
            and not is_soname_link(entry)
        ):
            remove_path(source_path)
            relocated_entries.append((source_path, canonical_path, "removed-stale"))
            continue

        shutil.move(source_path, canonical_path)
        os.symlink(os.path.join("x86_64-linux-gnu", entry), source_path)
        relocated_entries.append((source_path, canonical_path, "moved"))

    if report and relocated_entries:
        print_info("[*] Normalizing top-level /usr/lib libraries into multiarch...")
        for source_path, canonical_path, action in relocated_entries:
            if action == "removed-stale":
                print_info(f"  Removed stale {source_path} (canonical family present in {canonical_dir})")
            elif action == "removed-compat":
                print_info(f"  Removed top-level compat entry {source_path}; canonical copy is {canonical_path}")
            else:
                print_info(f"  Migrated {source_path} -> {canonical_path}")

    return relocated_entries

def cleanup_transient_workspace_artifacts(report=True):
    """Remove stale temp/cache artifacts that can accumulate in the workspace root."""
    transient_patterns = [
        "initramfs_build.*",
        "initramfs-check.*",
        "geminios-source-verify-*",
        "__pycache__",
        "*.root-owned-backup",
        "*.root-owned-backup-*",
    ]

    removed_paths = []
    for pattern in transient_patterns:
        for path in sorted(glob.glob(os.path.join(ROOT_DIR, pattern))):
            if not os.path.lexists(path):
                continue
            remove_path(path)
            removed_paths.append(path)

    if report and removed_paths:
        print_info("[*] Removing stale temp/cache workspace artifacts...")
        for path in removed_paths:
            print_info(f"  Removed {path}")
    elif report:
        print_success("  ✓ No stale temp/cache workspace artifacts found.")

    return removed_paths

def clean_system():
    print_section("=== Cleaning GeminiOS Build Environment ===")
    cleanup_transient_workspace_artifacts(report=True)
    dirs_to_remove = ["rootfs", "glibc-build", "logs", "isodir", "initramfs_build"]
    for d in dirs_to_remove:
        path = os.path.join(ROOT_DIR, d)
        if os.path.exists(path):
            print_info(f"[*] Removing {d}...")
            subprocess.run(f"rm -rf {path}", shell=True, executable="/usr/bin/bash")
    
    # Remove ISOs
    if os.path.exists("GeminiOS.iso"):
        os.remove("GeminiOS.iso")
    if os.path.exists(HOST_DEV_OVERLAY_FILE):
        os.remove(HOST_DEV_OVERLAY_FILE)
    
    print_success("[!] Clean completed.")

def sync_kernel():
    print_section("\n=== Syncing Kernel Image ===")
    kernel_src = os.path.join(ROOT_DIR, "external_dependencies/linux-6.6.14/arch/x86/boot/bzImage")
    kernel_dest = os.path.join(ROOT_DIR, "rootfs/boot/kernel")
    
    if os.path.exists(kernel_src):
        print_info(f"[*] Copying {kernel_src} to {kernel_dest} and zoneinfo...")
        os.makedirs(os.path.dirname(kernel_dest), exist_ok=True)
        subprocess.run(f"cp {kernel_src} {kernel_dest}", shell=True, executable="/usr/bin/bash")
        subprocess.run(f"cp -r /usr/share/zoneinfo rootfs/usr/share", shell=True, executable="/usr/bin/bash")
        return True
    else:
        print_warning(f" [WARNING] Kernel image not found at {kernel_src}")
        print_warning("    Ensure you have compiled the kernel manually as described in README.md")
        return False

def build_ginit(force=False, debug=False):
    """Special handler for ginit submodule"""
    print_info("[*] Building Ginit Core...")
    ginit_dir = os.path.join(ROOT_DIR, "ginit")
    if not os.path.exists(ginit_dir):
        print_error("ERROR: ginit directory not found!")
        return False

    if force:
        ret = run_command(
            "make clean",
            cwd=ginit_dir,
            use_target_env=True,
            debug=debug,
        )
        if ret != 0:
            print_error("ERROR: Failed to clean ginit core")
            return False
    
    # Run make inside ginit
    # We use run_command to ensure it uses the correct environment
    ret = run_command(
        "make",
        cwd=ginit_dir,
        use_target_env=True,
        debug=debug,
    )
    if ret != 0:
        print_error("ERROR: Failed to build ginit core")
        return False
    
    return True

def build_package(pkg_name, index, total, force=False, debug=False):
    if pkg_name == "geminios_core":
        if not build_ginit(force, debug):
            return False

    if not force and is_built(pkg_name):
        print(color(f"[{index}/{total}] Skipping {pkg_name} ", Colors.CYAN) + color("(Verified)", Colors.GREEN))
        return True

    print(color(f"[{index}/{total}] Building {pkg_name}...", Colors.BLUE), end="", flush=True)
    start_time = time.time()
    
    pkg_dir = os.path.join(PORTS_DIR, pkg_name)
    build_script = os.path.join(pkg_dir, "build.sh")
    log_file = os.path.join(LOG_DIR, f"{pkg_name}.log")
    
    if os.path.exists(log_file):
        os.remove(log_file)
        
    if not os.path.exists(build_script):
        print(color(" [SKIPPED]", Colors.YELLOW) + " (No build script)")
        return True

    # A few packages need a true native host toolchain/bootstrap environment.
    host_toolchain_packages = {"kernel_headers", "glibc", "wayland"}
    use_target_env = pkg_name not in host_toolchain_packages
    ret = run_command(build_script, cwd=pkg_dir, log_file=log_file, use_target_env=use_target_env, debug=debug)
    
    duration = time.time() - start_time
    if ret == 0:
        normalize_rootfs_multiarch_layout(report=debug)
        # Post-build Verification
        verification_issues = get_package_verification_issues(pkg_name)
        if not verification_issues:
            print(color(f" [DONE]", Colors.GREEN + Colors.BOLD) + f" ({duration:.2f}s)")
            return True
        else:
            print(color(f" [FAILED VERIFICATION]", Colors.RED + Colors.BOLD) + " (Artifacts missing)")
            print_error("    Verification issues:")
            for issue in verification_issues:
                print_error(f"     - {issue}")
            return False
    else:
        print(color(f" [FAILED]", Colors.RED + Colors.BOLD) + f" (Check {log_file})")
        # Print the last few lines of the log to help the user
        if os.path.exists(log_file):
            print_warning("\n--- Last 10 lines of log ---")
            try:
                with open(log_file, "r") as f:
                    lines = f.readlines()
                    for line in lines[-10:]:
                        print(f"  {line.strip()}")
            except:
                pass
            print_warning("----------------------------")
        return False

def verify_source_urls(requested_packages):
    cmd = [sys.executable, VERIFY_SOURCES_SCRIPT]
    cmd.extend(requested_packages)
    return subprocess.call(cmd, cwd=ROOT_DIR)

def copy_dev_environment():
    """Copies host C/C++ development environment (headers and libraries) to rootfs"""
    print_section("\n=== Installing C/C++ Development Environment ===")
    overlay_paths = load_host_dev_overlay_paths()

    def sanitize_overlay_destination(dest_path):
        """Remove stale broken symlinks so host-overlay copies can replace them cleanly."""
        if os.path.islink(dest_path) and not os.path.exists(dest_path):
            remove_path(dest_path)
            return True
        return False

    def cleanup_broken_overlay_symlinks():
        """Remove stale broken symlinks under dev-overlay target directories before copying."""
        candidate_dirs = [
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "x86_64-linux-gnu"),
            os.path.join(ROOT_DIR, "rootfs", "lib", "x86_64-linux-gnu"),
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "gcc"),
            os.path.join(ROOT_DIR, "rootfs", "usr", "include"),
            os.path.join(ROOT_DIR, "rootfs", "usr", "local", "include"),
        ]

        removed = 0
        for base_dir in candidate_dirs:
            if not os.path.isdir(base_dir):
                continue
            for dirpath, dirnames, filenames in os.walk(base_dir, topdown=True, followlinks=False):
                for name in filenames:
                    if sanitize_overlay_destination(os.path.join(dirpath, name)):
                        removed += 1
                for name in list(dirnames):
                    path = os.path.join(dirpath, name)
                    if sanitize_overlay_destination(path):
                        removed += 1
                        dirnames.remove(name)

        if removed:
            print_info(f"[*] Removed {removed} stale broken overlay symlinks before host copy.")

    cleanup_broken_overlay_symlinks()

    def record_overlay_tree(source_root, dest_root):
        source_root = os.path.realpath(source_root)
        rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
        for dirpath, dirnames, filenames in os.walk(source_root, topdown=True, followlinks=False):
            rel_dir = os.path.relpath(dirpath, source_root)
            dest_dir = dest_root if rel_dir == "." else os.path.join(dest_root, rel_dir)
            for dirname in list(dirnames):
                source_dir = os.path.join(dirpath, dirname)
                if os.path.islink(source_dir):
                    overlay_paths.add(
                        os.path.relpath(os.path.join(dest_dir, dirname), rootfs_dir).replace(os.sep, "/")
                    )
            for filename in filenames:
                overlay_paths.add(
                    os.path.relpath(os.path.join(dest_dir, filename), rootfs_dir).replace(os.sep, "/")
                )
    
    # 1. Resolve and Copy Headers
    print_info("[*] Copying standard headers from host...")

    required_target_headers = [
        os.path.join(ROOT_DIR, "rootfs", "usr", "include", "stdio.h"),
        os.path.join(ROOT_DIR, "rootfs", "usr", "include", "pthread.h"),
        os.path.join(ROOT_DIR, "rootfs", "usr", "include", "x86_64-linux-gnu", "bits", "pthreadtypes.h"),
    ]
    missing_target_headers = [path for path in required_target_headers if not os.path.exists(path)]
    if missing_target_headers:
        missing_display = ", ".join(os.path.relpath(path, ROOT_DIR) for path in missing_target_headers)
        print_warning(
            "[*] Target glibc headers are not fully staged yet "
            f"({missing_display}). Skipping host libc headers; glibc/kernel_headers must populate them."
        )
    
    # Get include paths from host g++
    res = subprocess.run("g++ -v -E -x c++ - < /dev/null 2>&1", shell=True, capture_output=True, text=True, executable="/usr/bin/bash")
    include_paths = []
    in_include_section = False
    for line in res.stdout.splitlines():
        if "#include <...> search starts here:" in line:
            in_include_section = True
            continue
        if "End of search list." in line:
            in_include_section = False
            continue
        if in_include_section:
            path = line.strip()
            if os.path.exists(path):
                if (
                    "/include/c++/" in path
                    or re.search(r"/include/[^/]+/c\+\+/", path)
                    or "/lib/gcc/" in path
                    or path == "/usr/local/include"
                ):
                    include_paths.append(path)

    # Ensure the architecture-specific libstdc++ headers are staged even if the
    # host compiler's verbose search output format changes.
    gcc_multiarch = subprocess.run(
        "g++ -print-multiarch",
        shell=True,
        capture_output=True,
        text=True,
        executable="/usr/bin/bash",
    ).stdout.strip()
    gcc_version = subprocess.run(
        "g++ -dumpversion",
        shell=True,
        capture_output=True,
        text=True,
        executable="/usr/bin/bash",
    ).stdout.strip()
    if gcc_multiarch and gcc_version:
        multiarch_cpp_include = os.path.join("/usr/include", gcc_multiarch, "c++", gcc_version)
        if os.path.exists(multiarch_cpp_include):
            include_paths.append(multiarch_cpp_include)

    # Ensure GCC internal headers are staged even if the search list omits them.
    gcc_internal_paths = [
        subprocess.run("g++ -print-file-name=include", shell=True, capture_output=True, text=True, executable="/usr/bin/bash").stdout.strip(),
        subprocess.run("g++ -print-file-name=include-fixed", shell=True, capture_output=True, text=True, executable="/usr/bin/bash").stdout.strip(),
    ]
    include_paths.extend(path for path in gcc_internal_paths if path and os.path.exists(path))
    
    # Deduplicate while preserving order
    seen = set()
    include_paths = [x for x in include_paths if not (x in seen or seen.add(x))]

    for path in include_paths:
        dest = os.path.join(ROOT_DIR, "rootfs", path.lstrip("/"))
        dest = resolve_rootfs_copy_destination(dest)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        print_info(f"  Copying {path} -> {dest}")
        subprocess.run(
            f"cp -a --no-preserve=ownership -n {path}/. {dest}/ 2>/dev/null || true",
            shell=True,
            executable="/usr/bin/bash",
        )
        record_overlay_tree(path, dest)

    # 2. Resolve and Copy Development Libraries (Static, Shared, and Objects)
    print_info("[*] Copying C/C++ development libraries and objects from host...")
    
    lib_search_paths = [
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib64",
        "/lib/x86_64-linux-gnu",
        "/lib64"
    ]
    
    # Dynamically find GCC lib dir
    gcc_lib_file = subprocess.run("gcc -print-libgcc-file-name", shell=True, capture_output=True, text=True, executable="/usr/bin/bash").stdout.strip()
    if gcc_lib_file:
        lib_search_paths.append(os.path.dirname(gcc_lib_file))
    
    # Target patterns to ensure we have everything needed for development
    target_patterns = [
        "*.so*", "*.a", "*.o"
    ]
    
    for lib_dir in lib_search_paths:
        if not os.path.exists(lib_dir): continue
        print_info(f"  Scanning {lib_dir} for libraries...")
        for pattern in target_patterns:
            find_cmd = f"find {lib_dir} -maxdepth 1 -name '{pattern}'"
            found_items = subprocess.run(find_cmd, shell=True, capture_output=True, text=True, executable="/usr/bin/bash").stdout.splitlines()
            for item_path in found_items:
                item_name = os.path.basename(item_path)
                
                # Determine where it should go in rootfs
                # We try to preserve the original path structure for development files
                dest = os.path.join(ROOT_DIR, "rootfs", item_path.lstrip("/"))
                dest = resolve_rootfs_copy_destination(dest)
                
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                sanitize_overlay_destination(dest)
                overlay_paths.add(os.path.relpath(dest, os.path.join(ROOT_DIR, "rootfs")).replace(os.sep, "/"))
                if not os.path.exists(dest):
                    if os.path.islink(item_path):
                         subprocess.run(f"cp -P {item_path} {dest}", shell=True, executable="/usr/bin/bash")
                    else:
                         subprocess.run(
                             f"cp -a --no-preserve=ownership {item_path} {dest}",
                             shell=True,
                             executable="/usr/bin/bash",
                         )

    save_host_dev_overlay_paths(overlay_paths)
    print_success("  ✓ Development environment installed.")

def normalize_dev_tree(path):
    """Recreate an existing dev tree as a writable user-owned copy if needed."""
    if not os.path.exists(path) or os.access(path, os.W_OK):
        return

    backup_path = f"{path}.root-owned-backup"
    suffix = 1
    while os.path.exists(backup_path):
        backup_path = f"{path}.root-owned-backup-{suffix}"
        suffix += 1

    print_warning(f"[*] Normalizing unwritable dev tree: {path}")
    os.rename(path, backup_path)
    os.makedirs(path, exist_ok=True)
    shutil.copytree(backup_path, path, dirs_exist_ok=True, symlinks=True)

def normalize_dev_environment():
    """Fix previously copied host dev trees that preserved root ownership."""
    candidate_paths = [
        os.path.join(ROOT_DIR, "rootfs", "usr", "include"),
        os.path.join(ROOT_DIR, "rootfs", "usr", "local", "include"),
    ]
    candidate_paths.extend(
        glob.glob(os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "x86_64-linux-gnu", "gcc", "*", "*", "include"))
    )
    candidate_paths.extend(
        glob.glob(os.path.join(ROOT_DIR, "rootfs", "usr", "include", "*", "c++", "*"))
    )
    candidate_paths.extend(
        glob.glob(os.path.join(ROOT_DIR, "rootfs", "usr", "lib64", "gcc", "*", "*", "include"))
    )

    for candidate in candidate_paths:
        normalize_dev_tree(candidate)

def prepare_rootfs():
    print_section("\n=== Preparing Rootfs Structure ===")
    cleanup_transient_workspace_artifacts(report=True)
    dirs = [
        "bin", "boot", "proc", "sys", "dev", "etc", "tmp", "mnt", "run", "sbin",
        "lib", "lib/x86_64-linux-gnu", "lib64", "lib64/x86_64-linux-gnu",
        "var/repo", "var/log", "var/tmp",
        "usr/bin", "usr/share", "usr/local", "usr/lib", "usr/lib/x86_64-linux-gnu",
        "usr/lib64", "usr/lib64/x86_64-linux-gnu", "usr/include",
        "bin/apps/system"
    ]
    for d in dirs:
        os.makedirs(os.path.join(ROOT_DIR, "rootfs", d), exist_ok=True)

    normalize_dev_environment()

    # Install Dev Environment
    copy_dev_environment()

    # Make Debian multiarch canonical before any package build runs so legacy
    # --libdir=/usr/lib64 installs still land in the right place via the
    # compatibility symlink instead of creating a second real tree.
    normalize_rootfs_multiarch_layout(report=True)

    # Remove problematic .la files
    subprocess.run(f"find {os.path.join(ROOT_DIR, 'rootfs')} -name '*.la' -delete", shell=True, executable="/usr/bin/bash")

def verify_rootfs_integrity():
    print_section("\n=== Verifying Rootfs Integrity ===")
    critical_files = [
        "bin/init",
        "bin/bash",
        "bin/sh",
        "bin/login",
        "sbin/getty",
        "boot/kernel",
        "usr/lib/grub/i386-pc/modinfo.sh",
        "usr/share/terminfo/l/linux",
        "etc/passwd",
        "bin/apps/system/gtop",
        "lib/x86_64-linux-gnu/libcrypt.so.1",
        "usr/lib/x86_64-linux-gnu/libstdc++.so.6",
        "usr/lib/x86_64-linux-gnu/libgcc_s.so.1",
        "usr/bin/python3",
        "usr/lib/x86_64-linux-gnu/libglib-2.0.so",
        "usr/lib/x86_64-linux-gnu/libgtk-3.so",
        "usr/lib/x86_64-linux-gnu/libjson-glib-1.0.so",
        "usr/lib/x86_64-linux-gnu/libdconf.so",
        "usr/lib/x86_64-linux-gnu/libinput.so",
        "usr/share/mime/magic",
        "bin/apps/system/gpkg-worker",
        "usr/share/glib-2.0/schemas/gschemas.compiled",
        "usr/share/fonts/TTF/Inter-Regular.otf",
        "usr/bin/Xwayland",
        "usr/bin/xdg-user-dirs-update",
        "bin/startwayland",
        "usr/lib/ginit/services/udevd.gservice",
        "usr/lib/ginit/services/elogind.gservice",
        "usr/lib/ginit/services/network.gservice"
    ]
    
    missing = False
    for f in critical_files:
        path = os.path.join(ROOT_DIR, "rootfs", f)
        if not os.path.exists(path):
            print_error(f"  [MISSING] {f}")
            missing = True
            
    if missing:
        print_error("FATAL: Rootfs integrity check failed. Some critical files are missing.")
        return False

    required_runtime_libs = [
        "usr/lib/x86_64-linux-gnu/libpam.so.0",
        "usr/lib/x86_64-linux-gnu/libpam_misc.so.0",
        "usr/lib/x86_64-linux-gnu/libelogind.so.0",
        "usr/lib/x86_64-linux-gnu/libsystemd.so.0",
        "usr/lib/x86_64-linux-gnu/libGLX.so.0",
        "usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0",
        "usr/lib/x86_64-linux-gnu/libGLX_mesa.so.0",
        "usr/lib/x86_64-linux-gnu/libgbm.so.1",
        "usr/lib/x86_64-linux-gnu/dri/swrast_dri.so",
        "usr/share/glvnd/egl_vendor.d/50_mesa.json",
    ]
    for rel_path in required_runtime_libs:
        path = os.path.join(ROOT_DIR, "rootfs", rel_path)
        if not os.path.exists(path):
            print_error(f"  [MISSING] {rel_path}")
            return False

    dbus_runtime_issues = get_dbus_runtime_abi_issues()
    if dbus_runtime_issues:
        print_error(f"  [FAILED] {dbus_runtime_issues[0]}")
        print_error("           A staged package likely overwrote GeminiOS DBus binaries or libraries.")
        return False
    print_success("  [OK] DBus runtime ABI")

    # Verify Python functionality
    print_info("[*] Verifying Python runtime...")
    env = os.environ.copy()
    env["PYTHONHOME"] = os.path.join(ROOT_DIR, "rootfs/usr")
    env["LD_LIBRARY_PATH"] = (
        f"{os.path.join(ROOT_DIR, 'rootfs/usr/lib/x86_64-linux-gnu')}:"
        f"{os.path.join(ROOT_DIR, 'rootfs/lib/x86_64-linux-gnu')}"
    )
    
    python_bin = os.path.join(ROOT_DIR, "rootfs/usr/bin/python3")
    if os.path.exists(python_bin):
        res = subprocess.run([python_bin, "-c", "import encodings; print('Python Encodings OK')"], 
                             env=env, capture_output=True, text=True)
        if res.returncode != 0:
            print_error(f"  [FAILED] Python runtime check: {res.stderr}")
            return False
        print_success("  [OK] Python runtime")
    
    print_success("[!] Rootfs integrity check PASSED.")
    return True

def finalize_rootfs():
    print_section("\n=== Finalizing Rootfs (Glue & Fixups) ===")
    
    # 1. Permissions (su/sudo)
    print_info("[*] Setting SUID permissions...")
    for tool in ["su", "sudo"]:
        path = os.path.join(ROOT_DIR, "rootfs/bin/apps/system", tool)
        if os.path.exists(path):
            subprocess.run(f"chmod u+s {path}", shell=True, executable="/usr/bin/bash")

    # 2. Critical Symlinks
    print_info("[*] Creating system symlinks...")
    symlinks = [
        ("usr/bin/Xorg", "usr/bin/X"),
        ("usr/bin/xinit", "usr/bin/startx"),
        ("usr/bin/bash", "bin/bash"),     # Create bin/bash -> ../usr/bin/bash
        ("bin/bash", "bin/sh"),           # Create bin/sh -> bash (in same dir)
        ("python3", "usr/bin/python"),
        ("python3", "usr/bin/python3") # Ensure both exist
    ]
    for target, link in symlinks:
        link_path = os.path.join(ROOT_DIR, "rootfs", link)
        if not os.path.exists(link_path):
            target_path = os.path.join(ROOT_DIR, "rootfs", target)
            if os.path.exists(target_path) or target == "bin/bash": 
                # Note: bin/bash might be a symlink we just defined, so exist check might fail if not careful.
                # However, order matters. We create bin/bash first.
                # But os.path.exists follows symlinks, so if bin/bash points to existing file, it returns true.
                
                # Calculate relative path for the symlink
                link_dir = os.path.dirname(link_path)
                rel_target = os.path.relpath(target_path, link_dir)
                
                print_info(f"  Creating symlink: {link} -> {rel_target}")
                try:
                    os.symlink(rel_target, link_path)
                except FileExistsError:
                    pass

    # 3. Database Updates
    print_info("[*] Updating system databases (Mime/Schemas)...")
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = (
        f"{os.path.join(ROOT_DIR, 'rootfs/usr/lib/x86_64-linux-gnu')}:"
        f"{os.path.join(ROOT_DIR, 'rootfs/lib/x86_64-linux-gnu')}"
    )
    
    # Glib Schemas
    schema_tool = os.path.join(ROOT_DIR, "rootfs/usr/bin/glib-compile-schemas")
    schema_dir = os.path.join(ROOT_DIR, "rootfs/usr/share/glib-2.0/schemas")
    if os.path.exists(schema_tool) and os.path.exists(schema_dir):
        glib_issues = get_package_verification_issues("glib")
        if glib_issues:
            print_warning(
                "  Skipping glib-compile-schemas because the staged GLib runtime is inconsistent: "
                + glib_issues[0]
            )
        else:
            subprocess.run([schema_tool, schema_dir], env=env)

    # Mime Database
    mime_tool = os.path.join(ROOT_DIR, "rootfs/usr/bin/update-mime-database")
    mime_dir = os.path.join(ROOT_DIR, "rootfs/usr/share/mime")
    if os.path.exists(mime_tool) and os.path.exists(mime_dir):
        mime_issues = get_package_verification_issues("libxml2") + get_package_verification_issues("shared-mime-info")
        if mime_issues:
            print_warning(
                "  Skipping update-mime-database because the staged MIME/libxml runtime is inconsistent: "
                + mime_issues[0]
            )
        else:
            subprocess.run([mime_tool, mime_dir], env=env)

    # 4. Create Live Marker
    # This file tells ginit that we are booting the Live CD (enabling autologin)
    # The installer will remove this file from the installed system.
    with open(os.path.join(ROOT_DIR, "rootfs/etc/geminios-live"), "w") as f:
        f.write("1")

    # 5. Seed gpkg configuration files. Debian testing is built-in; optional
    # GeminiOS-native repositories can be preseeded from build config.
    print_info("[*] Seeding gpkg repository configuration...")
    gpkg_dir = os.path.join(ROOT_DIR, "rootfs/etc/gpkg")
    gpkg_sources_dir = os.path.join(gpkg_dir, "sources.list.d")
    os.makedirs(gpkg_sources_dir, exist_ok=True)

    sources_list_path = os.path.join(gpkg_dir, "sources.list")
    if not os.path.exists(sources_list_path):
        with open(sources_list_path, "w") as f:
            f.write("")

    for entry in os.listdir(gpkg_sources_dir):
        if entry.endswith(".list"):
            os.remove(os.path.join(gpkg_sources_dir, entry))
    print_success("  ✓ Cleared staged secondary gpkg repositories")

    default_sources_dest = os.path.join(gpkg_sources_dir, "00-default.list")
    if os.path.exists(GPKG_DEFAULT_SOURCES_FILE):
        shutil.copy2(GPKG_DEFAULT_SOURCES_FILE, default_sources_dest)
        print_success(f"  ✓ Added default gpkg secondary repositories: {default_sources_dest}")
    else:
        print_success("  ✓ No default secondary gpkg repositories configured")

    for legacy_name in ("system-provides.list", "upgradeable-system.list"):
        legacy_path = os.path.join(gpkg_dir, legacy_name)
        if os.path.exists(legacy_path):
            os.remove(legacy_path)
            print_success(f"  ✓ Removed legacy gpkg config: {legacy_path}")

    upgrade_companions_dest = os.path.join(gpkg_dir, "upgrade-companions.conf")
    if os.path.exists(GPKG_UPGRADE_COMPANIONS_FILE):
        shutil.copy2(GPKG_UPGRADE_COMPANIONS_FILE, upgrade_companions_dest)
        print_success(f"  ✓ Added gpkg upgrade companions: {upgrade_companions_dest}")
    else:
        with open(upgrade_companions_dest, "w") as f:
            f.write("")

    debian_config_dest = os.path.join(gpkg_dir, "debian.conf")
    if os.path.exists(GPKG_DEBIAN_CONFIG_FILE):
        shutil.copy2(GPKG_DEBIAN_CONFIG_FILE, debian_config_dest)
        print_success(f"  ✓ Added gpkg Debian backend config: {debian_config_dest}")
    else:
        with open(debian_config_dest, "w") as f:
            f.write("")

    import_policy_dest = os.path.join(gpkg_dir, "import-policy.json")
    if os.path.exists(GPKG_IMPORT_POLICY_FILE):
        shutil.copy2(GPKG_IMPORT_POLICY_FILE, import_policy_dest)
        print_success(f"  ✓ Added gpkg import policy: {import_policy_dest}")
    else:
        with open(import_policy_dest, "w") as f:
            f.write("{}\n")

    # 6. Versioning
    release = get_geminios_release_info()
    print_info(f"[*] Setting system version: {release['display_version']} (build {release['build_id']})")
    with open(os.path.join(ROOT_DIR, "rootfs/etc/geminios-version"), "w") as f:
        f.write(release["display_version"] + "\n")
    with open(os.path.join(ROOT_DIR, "rootfs/etc/geminios-build-id"), "w") as f:
        f.write(release["build_id"] + "\n")
    
    with open(os.path.join(ROOT_DIR, "rootfs/etc/os-release"), "w") as f:
        f.write(f'NAME="{release["name"]}"\n')
        f.write(f'ID={release["id"]}\n')
        f.write(f'ID_LIKE="{release["id_like"]}"\n')
        f.write(f'VERSION="{release["display_version"]}"\n')
        f.write(f'PRETTY_NAME="{release["pretty_name"]}"\n')
        f.write(f'VERSION_ID="{release["version_id"]}"\n')
        f.write(f'VERSION_CODENAME="{release["codename"]}"\n')
        f.write(f'BUILD_ID="{release["build_id"]}"\n')
        f.write(f'IMAGE_ID="{release["image_id"]}"\n')
        f.write(f'IMAGE_VERSION="{release["snapshot_date"]}"\n')
        f.write(f'ANSI_COLOR="{release["ansi_color"]}"\n')
        f.write('HOME_URL="https://github.com/CreitinGameplays/geminios"\n')
        f.write('SUPPORT_URL="https://github.com/CreitinGameplays/geminios/issues"\n')
        f.write('BUG_REPORT_URL="https://github.com/CreitinGameplays/geminios/issues"\n')

    # 7. D-Bus Machine ID
    print_info("[*] Generating D-Bus machine-id...")
    machine_id_path = os.path.join(ROOT_DIR, "rootfs/etc/machine-id")
    dbus_uuid_path = os.path.join(ROOT_DIR, "rootfs/var/lib/dbus/machine-id")
    os.makedirs(os.path.dirname(dbus_uuid_path), exist_ok=True)
    
    if not os.path.exists(machine_id_path):
        # Try using host dbus-uuidgen but directed to a temp file, or just use python
        import uuid
        m_id = uuid.uuid4().hex
        with open(machine_id_path, "w") as f:
            f.write(m_id + "\n")
        # Link var/lib/dbus/machine-id to /etc/machine-id
        if os.path.exists(dbus_uuid_path): os.remove(dbus_uuid_path)
        os.symlink("/etc/machine-id", dbus_uuid_path)
        print_success(f"  ✓ Generated machine-id: {m_id}")

    # 8. Remove known-unused host runtime libraries that can leak in from the
    # development overlay. Keep this targeted to avoid breaking dlopen()-based
    # packages or future native ports.
    prune_unused_host_runtime_libs()

    # 9. Strip host dev-overlay leftovers before packaging the final image.
    prune_host_dev_overlay_artifacts()

    # 10. Restore multiarch compatibility symlinks for the in-OS toolchain.
    normalize_rootfs_multiarch_layout(report=True)

    # 11. Final Integrity Check
    if not verify_rootfs_integrity():
        print_error("FATAL: Final rootfs integrity check failed!")
        sys.exit(1)

def get_elf_needed(binary_path):
    """Return DT_NEEDED entries for an ELF binary/library."""
    result = subprocess.run(
        ["readelf", "-d", binary_path],
        capture_output=True,
        text=True,
        check=False,
    )
    needed = []
    for line in result.stdout.splitlines():
        if "(NEEDED)" not in line:
            continue
        start = line.find("[")
        end = line.find("]", start + 1)
        if start != -1 and end != -1:
            needed.append(line[start + 1:end])
    return needed

def get_elf_soname(binary_path):
    """Return the DT_SONAME entry for an ELF library, if present."""
    result = subprocess.run(
        ["readelf", "-d", binary_path],
        capture_output=True,
        text=True,
        check=False,
    )
    for line in result.stdout.splitlines():
        if "(SONAME)" not in line:
            continue
        start = line.find("[")
        end = line.find("]", start + 1)
        if start != -1 and end != -1:
            return line[start + 1:end]
    return None

def get_elf_interpreter(binary_path):
    """Return the PT_INTERP path for an ELF binary, if present."""
    result = subprocess.run(
        ["readelf", "-l", binary_path],
        capture_output=True,
        text=True,
        check=False,
    )
    for line in result.stdout.splitlines():
        if "Requesting program interpreter:" not in line:
            continue
        start = line.find("[")
        end = line.find("]", start + 1)
        if start != -1 and end != -1:
            return line[start + 1:end]
    return None

def find_rootfs_library(rootfs_dir, lib_filename):
    """Find a library within the target rootfs."""
    for search_path in [
        "lib/x86_64-linux-gnu",
        "usr/lib/x86_64-linux-gnu",
        "lib64",
        "usr/lib64",
        "lib",
        "usr/lib",
    ]:
        candidate = os.path.join(rootfs_dir, search_path, lib_filename)
        if os.path.exists(candidate):
            return candidate
    return None

def iter_rootfs_elf_files(rootfs_dir):
    """Yield likely ELF-bearing files from runtime-relevant rootfs paths."""
    candidate_dirs = [
        "bin",
        "sbin",
        "lib/x86_64-linux-gnu",
        "usr/bin",
        "usr/sbin",
        "usr/lib/x86_64-linux-gnu",
        "usr/libexec",
    ]

    seen = set()
    for rel_dir in candidate_dirs:
        base_dir = os.path.join(rootfs_dir, rel_dir)
        if not os.path.exists(base_dir):
            continue

        for dirpath, _, filenames in os.walk(base_dir):
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                if path in seen or not os.path.isfile(path):
                    continue
                seen.add(path)
                yield path

def collect_rootfs_needed_libs(rootfs_dir, excluded_paths=None):
    """Collect DT_NEEDED library names used by runtime ELF files."""
    excluded_paths = set(excluded_paths or [])
    needed = set()

    for path in iter_rootfs_elf_files(rootfs_dir):
        if path in excluded_paths:
            continue
        needed.update(get_elf_needed(path))

    return needed

def prune_unused_host_runtime_libs():
    """Remove known host-overlay runtime libraries when nothing in rootfs needs them."""
    print_info("[*] Pruning unused host-overlay runtime libraries...")

    rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
    host_multiarch_dirs = [
        os.path.join(rootfs_dir, "lib", "x86_64-linux-gnu"),
        os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu"),
    ]
    candidate_families = [
        {"label": "PAM", "soname": "libpam.so.0", "prefix": "libpam.so"},
        {"label": "PAM Misc", "soname": "libpam_misc.so.0", "prefix": "libpam_misc.so"},
        {"label": "SELinux", "soname": "libselinux.so.1", "prefix": "libselinux.so"},
        {"label": "SEPol", "soname": "libsepol.so.2", "prefix": "libsepol.so"},
    ]

    family_paths = {}
    all_candidate_paths = set()
    excluded_paths = set()
    manifest_owned_artifacts = set()

    for artifacts in PACKAGE_MANIFESTS.values():
        for artifact in artifacts:
            if any(ch in artifact for ch in "*?["):
                continue
            manifest_owned_artifacts.add(artifact.lstrip("/"))

    for base_dir in host_multiarch_dirs:
        if not os.path.isdir(base_dir):
            continue
        for dirpath, _, filenames in os.walk(base_dir):
            for filename in filenames:
                path = os.path.join(dirpath, filename)
                if os.path.isfile(path):
                    excluded_paths.add(path)

    for family in candidate_families:
        paths = []
        for base_dir in host_multiarch_dirs:
            if not os.path.isdir(base_dir):
                continue
            for entry in os.listdir(base_dir):
                if entry.startswith(family["prefix"]):
                    path = os.path.join(base_dir, entry)
                    paths.append(path)
                    all_candidate_paths.add(path)
        family_paths[family["soname"]] = sorted(set(paths))

    needed_libs = collect_rootfs_needed_libs(rootfs_dir, excluded_paths=excluded_paths)
    removed_count = 0

    if all_candidate_paths:
        for family in candidate_families:
            soname = family["soname"]
            paths = family_paths.get(soname, [])
            if not paths:
                continue

            manifest_owns_family = False
            for path in paths:
                rel_path = os.path.relpath(path, rootfs_dir).replace(os.sep, "/")
                basename = os.path.basename(rel_path)
                if (
                    rel_path in manifest_owned_artifacts
                    or any(
                        os.path.basename(owned_artifact).startswith(family["prefix"])
                        and os.path.dirname(owned_artifact) == os.path.dirname(rel_path)
                        for owned_artifact in manifest_owned_artifacts
                    )
                ):
                    manifest_owns_family = True
                    break

            if manifest_owns_family:
                print_info(f"  Keeping {family['label']} libraries; managed by built packages.")
                continue

            if soname in needed_libs:
                print_info(f"  Keeping {family['label']} libraries; still required by rootfs.")
                continue

            for path in paths:
                if os.path.lexists(path):
                    os.remove(path)
                    removed_count += 1
            print_success(f"  ✓ Removed unused {family['label']} library family.")

    if not excluded_paths:
        print_success("  ✓ No host multiarch runtime overlay found.")
        return

    if removed_count == 0:
        print_success("  ✓ No unused host-overlay runtime libraries needed pruning.")

def prune_host_dev_overlay_artifacts():
    """Remove host-overlay files that are not owned by built packages or needed at runtime."""
    print_info("[*] Pruning host development overlay artifacts...")

    overlay_paths = load_host_dev_overlay_paths()
    if not overlay_paths:
        print_success("  ✓ No host development overlay record found.")
        return

    rootfs_dir = os.path.join(ROOT_DIR, "rootfs")
    manifest_owned_artifacts = set()
    manifest_owned_targets = set()
    for artifacts in PACKAGE_MANIFESTS.values():
        for artifact in artifacts:
            if any(ch in artifact for ch in "*?["):
                continue
            rel_artifact = artifact.lstrip("/")
            manifest_owned_artifacts.add(rel_artifact)
            abs_artifact = os.path.join(rootfs_dir, rel_artifact)
            if os.path.exists(abs_artifact):
                real_artifact = os.path.realpath(abs_artifact)
                try:
                    if os.path.commonpath([rootfs_dir, real_artifact]) == rootfs_dir:
                        manifest_owned_targets.add(
                            os.path.relpath(real_artifact, rootfs_dir).replace(os.sep, "/")
                        )
                except ValueError:
                    pass

    needed_libs = collect_rootfs_needed_libs(rootfs_dir)
    soname_cache = {}
    kept_count = 0
    removed_count = 0

    protected_prefixes = (
        "usr/lib/gcc/",
        "usr/libexec/gcc/",
        "usr/include/c++/",
        "usr/include/x86_64-linux-gnu/c++/",
    )

    for rel_path in sorted(overlay_paths):
        abs_path = os.path.join(rootfs_dir, rel_path)
        if not os.path.lexists(abs_path):
            continue

        if rel_path in manifest_owned_artifacts:
            kept_count += 1
            continue

        if rel_path in manifest_owned_targets:
            kept_count += 1
            continue

        if rel_path.startswith(protected_prefixes):
            kept_count += 1
            continue

        basename = os.path.basename(rel_path)
        if basename in needed_libs:
            kept_count += 1
            continue

        if os.path.isfile(abs_path) and not os.path.islink(abs_path):
            soname = soname_cache.get(abs_path)
            if soname is None:
                soname = get_elf_soname(abs_path)
                soname_cache[abs_path] = soname
            if soname and soname in needed_libs:
                kept_count += 1
                continue

        if rel_path.startswith("usr/include/"):
            remove_path(abs_path)
            removed_count += 1
            continue

        if rel_path.endswith((".a", ".la", ".o")):
            remove_path(abs_path)
            removed_count += 1
            continue

        if rel_path.startswith(("usr/lib/x86_64-linux-gnu/", "lib/x86_64-linux-gnu/", "usr/lib/", "lib/")):
            remove_path(abs_path)
            removed_count += 1
            continue

        kept_count += 1

    for dirpath, _, _ in os.walk(rootfs_dir, topdown=False):
        if dirpath == rootfs_dir:
            continue
        if os.path.isdir(dirpath) and not os.listdir(dirpath):
            try:
                os.rmdir(dirpath)
            except OSError:
                pass

    print_success(f"  ✓ Removed {removed_count} unused host-overlay artifacts.")
    if kept_count:
        print_info(f"  Kept {kept_count} overlay artifacts because they are package-owned or still needed.")

def ensure_multiarch_dev_compat(report=True):
    """Collapse lib64 trees into Debian-style multiarch with compatibility symlinks."""
    if report:
        print_info("[*] Restoring multiarch compatibility trees...")

    def replace_with_symlink(path, target):
        if os.path.islink(path):
            if os.readlink(path) == target:
                return False
            os.unlink(path)
        elif os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.lexists(path):
            os.unlink(path)
        os.symlink(target, path)
        return True

    link_specs = [
        (
            os.path.join(ROOT_DIR, "rootfs", "lib", "x86_64-linux-gnu"),
            os.path.join(ROOT_DIR, "rootfs", "lib64"),
            "lib/x86_64-linux-gnu",
        ),
        (
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "x86_64-linux-gnu"),
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib64"),
            "lib/x86_64-linux-gnu",
        ),
        (
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "x86_64-linux-gnu", "pkgconfig"),
            os.path.join(ROOT_DIR, "rootfs", "usr", "lib", "pkgconfig"),
            "x86_64-linux-gnu/pkgconfig",
        ),
    ]

    linked_count = 0
    for source_dir, compat_link, compat_target in link_specs:
        if not os.path.isdir(source_dir):
            continue

        nested_compat = os.path.join(source_dir, "x86_64-linux-gnu")
        if not os.path.lexists(nested_compat):
            os.symlink(".", nested_compat)
            linked_count += 1

        if replace_with_symlink(compat_link, compat_target):
            linked_count += 1

    if report and linked_count:
        print_success(f"  ✓ Restored {linked_count} multiarch compatibility symlinks.")
    elif report:
        print_success("  ✓ Multiarch toolchain compatibility links already present.")

def copy_with_libs(binary_path, dest_dir, rootfs_dir, copy_bin=True):
    """Copies a binary and all its shared library dependencies to dest_dir"""
    if not os.path.exists(binary_path):
        print_warning(f"WARNING: Binary not found: {binary_path}")
        return False

    if copy_bin:
        # Copy the binary
        dest_bin = os.path.join(dest_dir, os.path.basename(binary_path))
        shutil.copy2(binary_path, dest_bin)
        os.chmod(dest_bin, 0o755)

    dest_lib_dir = os.path.join(dest_dir, "lib64")
    os.makedirs(dest_lib_dir, exist_ok=True)

    interpreter_name = "ld-linux-x86-64.so.2"
    interp_path = get_elf_interpreter(binary_path)
    if interp_path:
        interpreter_name = os.path.basename(interp_path)

    to_process = [binary_path]
    processed = set()
    copied = set()

    while to_process:
        current = to_process.pop()
        if current in processed:
            continue
        processed.add(current)

        for lib_filename in get_elf_needed(current):
            candidate = find_rootfs_library(rootfs_dir, lib_filename)
            if not candidate:
                print_warning(f"WARNING: Could not find library {lib_filename} in rootfs for {binary_path}")
                continue

            real_lib = os.path.realpath(candidate)
            real_basename = os.path.basename(real_lib)
            dest_real = os.path.join(dest_lib_dir, real_basename)
            if real_basename not in copied:
                shutil.copy2(real_lib, dest_real)
                copied.add(real_basename)
                to_process.append(real_lib)

            if candidate != real_lib:
                link_name = os.path.join(dest_lib_dir, lib_filename)
                if os.path.lexists(link_name):
                    os.remove(link_name)
                os.symlink(real_basename, link_name)

    if not os.path.exists(os.path.join(dest_lib_dir, interpreter_name)):
        src_interp = find_rootfs_library(rootfs_dir, interpreter_name)
        if src_interp:
            shutil.copy2(src_interp, os.path.join(dest_lib_dir, interpreter_name))

    return True

def create_minimal_initramfs():
    print_section("\n=== Building Minimal Initramfs (Live CD Bootloader) ===")

    stale_work_dir = os.path.join(ROOT_DIR, "initramfs_build")
    if os.path.exists(stale_work_dir):
        try:
            shutil.rmtree(stale_work_dir)
        except PermissionError:
            print_warning(f"WARNING: Could not remove stale {stale_work_dir}; using a fresh temporary staging dir instead.")

    work_dir = tempfile.mkdtemp(prefix="initramfs_build.", dir=ROOT_DIR)

    try:
        # structure
        for d in ["bin", "sbin", "lib64", "mnt", "dev", "proc", "sys", "run", "usr/bin", "usr/sbin"]:
            os.makedirs(os.path.join(work_dir, d), exist_ok=True)

        # Symlink lib to lib64
        if not os.path.exists(os.path.join(work_dir, "lib")):
            os.symlink("lib64", os.path.join(work_dir, "lib"))

        rootfs = os.path.join(ROOT_DIR, "rootfs")

        # Essential binaries
        essential_tools = [
            ("bash", ["bin/bash", "usr/bin/bash"]),
            ("sh", ["bin/sh", "usr/bin/sh"]),
            ("mount", ["usr/bin/mount", "bin/mount", "bin/apps/system/mount"]),
            ("ls", ["usr/bin/ls", "bin/ls", "bin/apps/system/ls"]),
            ("mkdir", ["usr/bin/mkdir", "bin/mkdir", "bin/apps/system/mkdir"]),
            ("cat", ["usr/bin/cat", "bin/cat", "bin/apps/system/cat"]),
            ("sleep", ["usr/bin/sleep", "bin/sleep", "bin/apps/system/sleep"]),
            ("umount", ["usr/bin/umount", "bin/umount", "bin/apps/system/umount"]),
        ]

        binaries = []
        for tool_name, paths in essential_tools:
            found = False
            for path in paths:
                if os.path.exists(os.path.join(rootfs, path)):
                    binaries.append((path, "bin"))
                    found = True
                    break
            if not found:
                 print_warning(f"WARNING: Essential tool {tool_name} not found in rootfs!")

        # Locate switch_root
        if os.path.exists(os.path.join(rootfs, "sbin/switch_root")):
            binaries.append(("sbin/switch_root", "sbin"))
        elif os.path.exists(os.path.join(rootfs, "usr/sbin/switch_root")):
             binaries.append(("usr/sbin/switch_root", "usr/sbin"))

        for src_rel, dest_rel in binaries:
            src_path = os.path.join(rootfs, src_rel)
            dest_path = os.path.join(work_dir, dest_rel)

            if not os.path.exists(src_path):
                 print_warning(f"WARNING: Initramfs binary missing: {src_rel}")
                 continue

            # Always resolve to real file to avoid broken symlinks in minimal env
            real_src = os.path.realpath(src_path)

            # Determine destination filename (preserve the name requested, e.g. sh)
            dest_file = os.path.join(dest_path, os.path.basename(src_rel))

            # Copy the actual content
            shutil.copy2(real_src, dest_file)
            os.chmod(dest_file, 0o755)

            # Copy dependencies into the initramfs root so the canonical loader/lib dirs exist there.
            copy_with_libs(real_src, work_dir, rootfs, copy_bin=False)

        # Create init script
        init_script = """#!/bin/bash
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /run

echo "GeminiOS: Searching for boot media..."

# Find CDROM containing root.sfs
CDROM_DEV=""
sleep 2

for dev in /dev/sr* /dev/sd*; do
    [ -e "$dev" ] || continue
    echo "Checking device $dev..."
    mkdir -p /mnt/cdrom
    if mount -t iso9660 -o ro "$dev" /mnt/cdrom; then
        if [ -f "/mnt/cdrom/root.sfs" ]; then
            CDROM_DEV="$dev"
            echo "Found boot media at $dev"
            break
        fi
        echo "Device $dev does not contain root.sfs, unmounting."
        umount /mnt/cdrom
    else
        echo "Failed to mount $dev as iso9660."
    fi
done

if [ -z "$CDROM_DEV" ]; then
    echo "FATAL: Could not find boot media (root.sfs)!"
    echo "Available devices:"
    ls -d /dev/sd* /dev/sr*
    exec /bin/bash
fi

# Set up OverlayFS
echo "Setting up OverlayFS..."
mkdir -p /mnt/ro
mkdir -p /mnt/rw

# Mount SquashFS
mount -t squashfs -o loop /mnt/cdrom/root.sfs /mnt/ro

# Mount TmpFS for writes
mount -t tmpfs tmpfs /mnt/rw

# Create overlay directories
mkdir -p /mnt/rw/upper
mkdir -p /mnt/rw/work
mkdir -p /new_root

# Mount Overlay
mount -t overlay overlay -o lowerdir=/mnt/ro,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work /new_root

# Move virtual filesystems
mount --move /dev /new_root/dev
mount --move /proc /new_root/proc
mount --move /sys /new_root/sys
mount --move /run /new_root/run

# Unmount boot media to allow switch_root to clean up
umount /mnt/cdrom

# Switch root
echo "Switching to real root..."
exec switch_root /new_root /bin/init
"""
        with open(os.path.join(work_dir, "init"), "w") as f:
            f.write(init_script)
        os.chmod(os.path.join(work_dir, "init"), 0o755)

        # Pack it
        print_info("[*] Compressing minimal initramfs...")
        os.makedirs(os.path.join(ROOT_DIR, "isodir/boot"), exist_ok=True)
        initramfs_out = os.path.join(ROOT_DIR, "isodir/boot/initramfs.cpio.lz4")

        pack_cmd = (
            f"cd {work_dir} && "
            f"find . -print0 | cpio --null -o --format=newc | lz4 -l -T0 > {initramfs_out}"
        )
        run_command(pack_cmd)
        return True
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

def create_iso():
    finalize_rootfs()
    print_section("\n=== Packaging GeminiOS ISO (Live CD) ===")
    
    # 0. Clean isodir
    # Always ensure the directory structure exists
    os.makedirs("isodir/boot/grub", exist_ok=True)
        
    # 1. Create SquashFS of Rootfs
    print_info("[*] Creating root.sfs (SquashFS)...")
    sfs_path = "isodir/root.sfs"
    if os.path.exists(sfs_path):
        os.remove(sfs_path)
        
    # Using zstd with level 1 for maximum speed/compression balance during development
    # Disabling xattrs also gives a bit of speedup
    mksquashfs_cmd = f"mksquashfs rootfs {sfs_path} -comp zstd -Xcompression-level 1 -no-xattrs -noappend -wildcards -all-root -e staging"
    if run_command(mksquashfs_cmd) != 0:
        print_error(" [FAILED] (mksquashfs)")
        return False
        
    # 2. Build Minimal Initramfs
    if not create_minimal_initramfs():
        return False

    # 3. Prepare Kernel
    print_info("[*] Preparing kernel...")
    kernel_src = os.path.join(ROOT_DIR, "rootfs/boot/kernel")
    kernel_dest = "isodir/boot/kernel"
    if not os.path.exists(kernel_src):
        # Fallback to source
        kernel_src = os.path.join(ROOT_DIR, "external_dependencies/linux-6.6.14/arch/x86/boot/bzImage")
    
    if os.path.exists(kernel_src):
         shutil.copy2(kernel_src, kernel_dest)
    else:
        print_error(f" [FAILED] (Kernel not found at {kernel_src})")
        return False

    # 4. Generate GRUB config
    print_info("[*] Generating GRUB config...")
    grub_conf = """set timeout=3
set default=0

menuentry "GeminiOS Live" {
    linux /boot/kernel console=tty0 console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200 net.ifnames=0
    initrd /boot/initramfs.cpio.lz4
}
"""
    with open("isodir/boot/grub/grub.cfg", "w") as f:
        f.write(grub_conf)

    # 5. Build ISO
    release = get_geminios_release_info()
    iso_name = release["iso_name"]
    print_info(f"[*] Building {iso_name}...")
    iso_cmd = f"grub-mkrescue -o {iso_name} isodir"
    if run_command(iso_cmd) != 0:
        print_error(" [FAILED] (grub-mkrescue)")
        return False

    # Create symlink for convenience
    if os.path.lexists("GeminiOS.iso"):
        os.remove("GeminiOS.iso")
    os.symlink(iso_name, "GeminiOS.iso")

    print_success(f"[!] ISO built successfully: {iso_name}")
    return True

def main():
    if "--help" in sys.argv:
        print_section("=== GeminiOS Builder Help ===")
        print(f"Usage: {sys.argv[0]} [options] [package_names...]")
        print("\nOptions:")
        print("  --clean     Clean the entire build environment (rootfs, logs, etc.)")
        print("  --verify-sources  Verify port source URLs without building")
        print("  --force     Force rebuild of specified packages (ignoring verification)")
        print("  --debug     Enable verbose debug logging")
        print("  --help      Show this help message")
        print("\nExamples:")
        print(f"  {sys.argv[0]}                   # Build all packages")
        print(f"  {sys.argv[0]} --clean           # Clean everything")
        print(f"  {sys.argv[0]} --verify-sources  # Verify all port source URLs")
        print(f"  {sys.argv[0]} bash coreutils    # Build specific packages")
        print(f"  {sys.argv[0]} bash --force      # Force rebuild bash")
        sys.exit(0)

    if "--clean" in sys.argv:
        clean_system()
        sys.exit(0)

    if "--verify-sources" in sys.argv:
        requested_packages = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
        if requested_packages:
            valid_requested_packages = []
            invalid = [pkg for pkg in requested_packages if pkg not in PACKAGES]
            if invalid:
                for pkg in invalid:
                    print_warning(f"WARNING: Package '{pkg}' not found in PACKAGES list.")
            for pkg in requested_packages:
                if pkg in PACKAGES:
                    valid_requested_packages.append(pkg)
            if not valid_requested_packages:
                print_error("ERROR: No valid packages specified for source verification.")
                sys.exit(1)
            requested_packages = valid_requested_packages
        sys.exit(verify_source_urls(requested_packages))

    os.makedirs(LOG_DIR, exist_ok=True)
    prepare_rootfs()
    sync_kernel()
    
    force_rebuild = "--force" in sys.argv
    debug_mode = "--debug" in sys.argv
    forced_packages = set()
    
    # Filter out flags to get requested packages
    requested_packages = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    
    packages_to_build = []
    if requested_packages:
        valid_requested_packages = []
        for pkg in requested_packages:
            if pkg in PACKAGES:
                valid_requested_packages.append(pkg)
            else:
                print_warning(f"WARNING: Package '{pkg}' not found in PACKAGES list.")

        if not valid_requested_packages:
            print_error("ERROR: No valid packages specified to build.")
            sys.exit(1)

        try:
            packages_to_build = resolve_requested_packages(valid_requested_packages)
            if force_rebuild:
                forced_packages = set(valid_requested_packages)
        except ValueError as exc:
            print_error(f"ERROR: {exc}")
            sys.exit(1)
    else:
        # Build everything
        packages_to_build = PACKAGES
        if force_rebuild:
            forced_packages = set(PACKAGES)

    print_section("=== GeminiOS Ports Builder ===")
    
    total_pkgs = len(packages_to_build)
    for i, pkg in enumerate(packages_to_build, 1):
        force_pkg = pkg in forced_packages
        if not build_package(pkg, i, total_pkgs, force=force_pkg, debug=debug_mode):
            print_error(f"\nFATAL: Build failed at package '{pkg}'")
            sys.exit(1)
            
    if create_iso():
        print_success("\n[!] Build completed successfully!")
        print_info("\nRun: qemu-system-x86_64 -cdrom GeminiOS.iso -m 2G -serial stdio -smp 2 -vga std -enable-kvm")
        print_info("Run with a disk: qemu-system-x86_64 -cdrom GeminiOS.iso -m 2G -serial stdio -hda disk.qcow2 -smp 2 -vga std -enable-kvm")
        print_info("Run with a disk but first boot the ISO: qemu-system-x86_64 -cdrom GeminiOS.iso -m 2G -serial stdio -hda disk.qcow2 -boot d -smp 2 -vga std -enable-kvm")
        print(color("Remove the -enable-kvm flag if your host does not support it.", Colors.DIM))
    else:
        print_error("\nFATAL: ISO creation failed")
        sys.exit(1)

if __name__ == "__main__":
    main()

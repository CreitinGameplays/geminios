#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import json
import shutil
import filecmp
import glob
import re
import tempfile
import gzip
import fnmatch
import shlex
import socket
import stat
import urllib.request
import urllib.error
from urllib.parse import urljoin
from datetime import datetime, timezone

# Ensure consistent command output parsing across different locales
os.environ["LC_ALL"] = "C"

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
LOG_DIR = os.environ.get("GEMINIOS_LOG_DIR", os.path.join(ROOT_DIR, "logs"))
ENV_CONFIG = os.path.join(BUILD_SYSTEM_DIR, "env_config.sh")
MANIFEST_FILE = os.path.join(BUILD_SYSTEM_DIR, "package_manifests.json")
PORT_BUILD_MODES_FILE = os.path.join(BUILD_SYSTEM_DIR, "port_build_modes.json")
BOOTSTRAP_RUNTIME_MANIFEST = os.path.join(BUILD_SYSTEM_DIR, "bootstrap_runtime_packages.txt")
BOOTSTRAP_TOOLCHAIN_MANIFEST = os.path.join(BUILD_SYSTEM_DIR, "bootstrap_toolchain_packages.txt")
VERIFY_SOURCES_SCRIPT = os.path.join(ROOT_DIR, "tools", "verify_source_urls.py")
SYS_INFO_HEADER = os.path.join(ROOT_DIR, "src", "sys_info.h")
BOOTSTRAP_ROOTFS_DIR = os.path.join(ROOT_DIR, "bootstrap_rootfs")
BUILD_SYSROOT_DIR = os.path.join(ROOT_DIR, "build_sysroot")
FINAL_ROOTFS_DIR = os.path.join(ROOT_DIR, "rootfs")
ROOTFS_DIR = BUILD_SYSROOT_DIR
OUTPUT_DIR = os.environ.get("GEMINIOS_OUTPUT_DIR", os.path.join(ROOT_DIR, "output"))
BOOTSTRAP_CACHE_DIR = os.environ.get(
    "GEMINIOS_BOOTSTRAP_CACHE_DIR",
    os.path.join(ROOT_DIR, "external_dependencies", "debian-bootstrap"),
)
ISO_WORK_DIR = os.environ.get("GEMINIOS_ISO_WORK_DIR", os.path.join(ROOT_DIR, "isodir"))
ISO_OUTPUT_DIR = os.environ.get("GEMINIOS_ISO_OUTPUT_DIR", ROOT_DIR)
ISO_SYMLINK_PATH = os.path.join(ROOT_DIR, "GeminiOS.iso")
RUNTIME_CLOSURE_REPORT = os.path.join(OUTPUT_DIR, "runtime-closure.json")
BOOTSTRAP_DOWNLOAD_RETRIES = 6
BOOTSTRAP_DOWNLOAD_TIMEOUT = 60
BOOTSTRAP_DOWNLOAD_CHUNK_SIZE = 1024 * 256
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
PKGCONFIG_CANONICAL_LIBDIR = "/usr/lib/x86_64-linux-gnu"
PKGCONFIG_MULTIARCH_DIR = os.path.join("usr", "lib", "x86_64-linux-gnu", "pkgconfig")


def read_env_config_export(var_name, default_value):
    """Read a simple exported variable from env_config.sh."""
    if not os.path.exists(ENV_CONFIG):
        return default_value

    pattern = re.compile(
        rf"^\s*export\s+{re.escape(var_name)}=(['\"]?)(.*?)\1\s*$"
    )

    try:
        with open(ENV_CONFIG, "r", encoding="utf-8") as env_file:
            for line in env_file:
                match = pattern.match(line.strip())
                if match:
                    return match.group(2)
    except OSError:
        pass

    return default_value


KERNEL_VERSION = read_env_config_export("KERNEL_VERSION", "linux-7.0-rc5")
EXTERNAL_DEPENDENCIES_DIR = os.path.join(ROOT_DIR, "external_dependencies")
KERNEL_BZIMAGE_PATH = os.path.join(
    EXTERNAL_DEPENDENCIES_DIR, KERNEL_VERSION, "arch", "x86", "boot", "bzImage"
)
KERNEL_BZIMAGE_GLOB = os.path.join(
    EXTERNAL_DEPENDENCIES_DIR, "linux-*", "arch", "x86", "boot", "bzImage"
)
PKGCONFIG_STAGE_ROOTS = tuple(
    dict.fromkeys(
        path
        for path in [BOOTSTRAP_ROOTFS_DIR, BUILD_SYSROOT_DIR, FINAL_ROOTFS_DIR, ROOTFS_DIR]
        if path
    )
)
PKGCONFIG_LEAK_MARKERS = tuple(
    dict.fromkeys(path for path in [ROOT_DIR, *PKGCONFIG_STAGE_ROOTS] if path)
)


def kernel_tree_name_from_bzimage(kernel_bzimage_path):
    """Return the kernel source directory name for a bzImage path."""
    relpath = os.path.relpath(kernel_bzimage_path, EXTERNAL_DEPENDENCIES_DIR)
    return relpath.split(os.sep, 1)[0]


def resolve_kernel_bzimage_path():
    """Prefer the configured kernel image and fall back to the newest compiled one."""
    if os.path.exists(KERNEL_BZIMAGE_PATH):
        return KERNEL_BZIMAGE_PATH, False

    compiled_images = [
        path for path in glob.glob(KERNEL_BZIMAGE_GLOB) if os.path.exists(path)
    ]
    if not compiled_images:
        return KERNEL_BZIMAGE_PATH, False

    compiled_images.sort(key=lambda path: (os.path.getmtime(path), path))
    return compiled_images[-1], True
PKGCONFIG_LEGACY_LIBDIR_VALUES = {
    "/usr/lib",
    "/usr/lib64",
    "/lib64",
    "/lib/x86_64-linux-gnu",
    "/usr/lib/x86_64-linux-gnu",
    "${exec_prefix}/lib",
    "${exec_prefix}/lib64",
    "${exec_prefix}/lib/x86_64-linux-gnu",
    "${prefix}/lib",
    "${prefix}/lib64",
    "${prefix}/lib/x86_64-linux-gnu",
}
DBUS_HELPER_REL_PATH = os.path.join("usr", "lib", "dbus-1.0", "dbus-daemon-launch-helper")
DBUS_HELPER_REQUIRED_MODE = 0o4754
DBUS_HELPER_REQUIRED_UID = 0
DBUS_HELPER_REQUIRED_GID = 18

# Load Manifests
try:
    with open(MANIFEST_FILE, "r") as f:
        PACKAGE_MANIFESTS = json.load(f)
except FileNotFoundError:
    print_warning("WARNING: Package manifests file not found. Verification will be limited.")
    PACKAGE_MANIFESTS = {}

try:
    with open(PORT_BUILD_MODES_FILE, "r") as f:
        PORT_BUILD_MODES = json.load(f)
except FileNotFoundError:
    PORT_BUILD_MODES = {"default": "target", "modes": {}}

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
    "selinux_userspace",
    "refpolicy",
    "util-linux",
    "e2fsprogs",
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
    "selinux_userspace": ["pcre2", "libcap", "gettext", "python", "pkg-config", "bison", "flex"],
    "refpolicy": ["selinux_userspace"],
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

def get_port_build_mode(pkg_name):
    """Return the declared build mode for a port."""
    return PORT_BUILD_MODES.get("modes", {}).get(pkg_name, PORT_BUILD_MODES.get("default", "target"))

def audit_port_build_script(pkg_name):
    """Return static build-script issues that would leak host tools into target builds."""
    build_mode = get_port_build_mode(pkg_name)
    if build_mode == "host-only-tool":
        return [], []

    build_script = os.path.join(PORTS_DIR, pkg_name, "build.sh")
    if not os.path.exists(build_script):
        return [], []

    with open(build_script, "r") as f:
        lines = f.readlines()

    issues = []
    warnings = []
    host_override_patterns = [
        ("CC", re.compile(r'^\s*(?:export\s+)?CC\s*=\s*["\']?gcc(?:["\']|\s|$)')),
        ("CXX", re.compile(r'^\s*(?:export\s+)?CXX\s*=\s*["\']?g\+\+(?:["\']|\s|$)')),
        ("AR", re.compile(r'^\s*(?:export\s+)?AR\s*=\s*["\']?ar(?:["\']|\s|$)')),
        ("RANLIB", re.compile(r'^\s*(?:export\s+)?RANLIB\s*=\s*["\']?ranlib(?:["\']|\s|$)')),
    ]
    pkg_config_disable_pattern = re.compile(r'^\s*(?:export\s+)?PKG_CONFIG\s*=\s*["\']?/bin/false["\']?\s*$')
    python_setup_install_pattern = re.compile(r'\bsetup\.py\s+install\b')

    for lineno, raw_line in enumerate(lines, 1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        for tool_name, pattern in host_override_patterns:
            if pattern.search(raw_line):
                issues.append(
                    f"{pkg_name} build script line {lineno} forces host {tool_name}; use builder-provided target toolchain instead"
                )
        if pkg_config_disable_pattern.search(raw_line):
            warnings.append(
                f"{pkg_name} build script line {lineno} disables pkg-config; verify this is intentional for staged target builds"
            )
        if python_setup_install_pattern.search(raw_line) and "TARGET_PYTHON" not in raw_line:
            issues.append(
                f"{pkg_name} build script line {lineno} installs a Python package without TARGET_PYTHON; use the staged Python wrapper for target installs"
            )

    return issues, warnings

def audit_requested_port_scripts(packages):
    """Audit requested package build scripts for patterns that break hermetic target builds."""
    issues = []
    warnings = []
    for pkg_name in packages:
        pkg_issues, pkg_warnings = audit_port_build_script(pkg_name)
        issues.extend(pkg_issues)
        warnings.extend(pkg_warnings)
    return issues, warnings

def read_manifest_lines(path):
    """Read newline-separated manifest entries, ignoring comments and blanks."""
    entries = []
    if not os.path.exists(path):
        return entries

    with open(path, "r") as f:
        for line in f:
            entry = line.strip()
            if not entry or entry.startswith("#"):
                continue
            entries.append(entry)
    return entries

def load_debian_bootstrap_config():
    """Load Debian metadata bootstrap URLs from gpkg's Debian config."""
    config = {}
    if os.path.exists(GPKG_DEBIAN_CONFIG_FILE):
        with open(GPKG_DEBIAN_CONFIG_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()

    packages_url = config.get("PACKAGES_URL", "https://deb.debian.org/debian/dists/testing/main/binary-amd64/Packages.gz")
    base_url = config.get("BASE_URL", "https://deb.debian.org/debian")
    return base_url.rstrip("/") + "/", packages_url

def format_bytes(num_bytes):
    """Render a byte count in a compact human-readable format."""
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    value = float(max(num_bytes, 0))
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}"
        value /= 1024.0
    return f"{value:.1f}TiB"

def format_duration(seconds):
    """Render a duration in a compact HH:MM:SS or MM:SS format."""
    seconds = max(int(seconds), 0)
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"

def print_dynamic_status(message, done=False):
    """Print a dynamic single-line status when attached to a TTY."""
    stream = sys.stdout
    if stream.isatty():
        padded = message.ljust(110)
        stream.write(("\r" if not done else "\r") + padded)
        if done:
            stream.write("\n")
        stream.flush()
    else:
        if done:
            print(message)

def render_download_progress(label, downloaded_bytes, total_bytes, start_time):
    """Render a download-progress line with throughput and ETA."""
    elapsed = max(time.time() - start_time, 0.001)
    speed = downloaded_bytes / elapsed
    if total_bytes:
        percent = min(downloaded_bytes / total_bytes, 1.0) * 100.0
        eta_seconds = (total_bytes - downloaded_bytes) / speed if speed > 0 else 0
        return (
            f"[*] {label}: {percent:5.1f}% "
            f"({format_bytes(downloaded_bytes)}/{format_bytes(total_bytes)}) "
            f"{format_bytes(speed)}/s eta {format_duration(eta_seconds)}"
        )
    return f"[*] {label}: {format_bytes(downloaded_bytes)} downloaded at {format_bytes(speed)}/s"

def fetch_url_cached(url, dest_path, label=None, retries=BOOTSTRAP_DOWNLOAD_RETRIES):
    """Download a URL into the local cache with resume/retry support."""
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    if os.path.exists(dest_path) and os.path.getsize(dest_path) > 0:
        return dest_path

    part_path = dest_path + ".part"
    label = label or os.path.basename(dest_path)
    last_error = None

    for attempt in range(1, retries + 1):
        resume_from = os.path.getsize(part_path) if os.path.exists(part_path) else 0
        request = urllib.request.Request(url)
        if resume_from > 0:
            request.add_header("Range", f"bytes={resume_from}-")

        try:
            with urllib.request.urlopen(request, timeout=BOOTSTRAP_DOWNLOAD_TIMEOUT) as response:
                status = getattr(response, "status", response.getcode())
                content_length = response.headers.get("Content-Length")
                if resume_from > 0 and status != 206:
                    # Server ignored resume support; restart the partial download cleanly.
                    if os.path.exists(part_path):
                        os.remove(part_path)
                    resume_from = 0

                total_bytes = None
                if content_length is not None:
                    try:
                        total_bytes = int(content_length)
                        if status == 206:
                            total_bytes += resume_from
                    except ValueError:
                        total_bytes = None

                start_time = time.time()
                downloaded_bytes = resume_from
                last_update = 0.0
                mode = "ab" if resume_from > 0 and status == 206 else "wb"
                with open(part_path, mode) as output:
                    while True:
                        chunk = response.read(BOOTSTRAP_DOWNLOAD_CHUNK_SIZE)
                        if not chunk:
                            break
                        output.write(chunk)
                        downloaded_bytes += len(chunk)
                        now = time.time()
                        if now - last_update >= 0.1:
                            print_dynamic_status(
                                render_download_progress(label, downloaded_bytes, total_bytes, start_time),
                                done=False,
                            )
                            last_update = now

                print_dynamic_status(
                    render_download_progress(label, downloaded_bytes, total_bytes, start_time),
                    done=True,
                )
                os.replace(part_path, dest_path)
                return dest_path
        except (urllib.error.URLError, urllib.error.HTTPError, ConnectionResetError, TimeoutError, socket.timeout, OSError) as exc:
            last_error = exc
            wait_seconds = min(2 ** (attempt - 1), 20)
            print_warning(f"WARNING: Download failed for {label} (attempt {attempt}/{retries}): {exc}")
            if attempt == retries:
                break
            print_info(f"[*] Retrying {label} in {wait_seconds}s using cached partial data...")
            time.sleep(wait_seconds)

    raise RuntimeError(f"Failed to download {label} after {retries} attempts: {last_error}")

def parse_debian_packages_metadata(text):
    """Parse a Debian Packages file into a name->metadata map."""
    entries = {}
    current = {}
    current_key = None

    def flush_entry():
        nonlocal current, current_key
        package_name = current.get("Package")
        if package_name and package_name not in entries:
            entries[package_name] = current
        current = {}
        current_key = None

    for raw_line in text.splitlines():
        if not raw_line:
            flush_entry()
            continue
        if raw_line.startswith(" "):
            if current_key:
                current[current_key] = current.get(current_key, "") + "\n" + raw_line[1:]
            continue
        if ":" not in raw_line:
            continue
        key, value = raw_line.split(":", 1)
        current_key = key.strip()
        current[current_key] = value.strip()

    flush_entry()
    return entries

def load_debian_package_index():
    """Load and cache Debian package metadata used for stage0/bootstrap."""
    base_url, packages_url = load_debian_bootstrap_config()
    packages_gz = os.path.join(BOOTSTRAP_CACHE_DIR, "Packages.gz")
    packages_txt = os.path.join(BOOTSTRAP_CACHE_DIR, "Packages")

    for attempt in range(2):
        fetch_url_cached(packages_url, packages_gz, label="Debian package index")
        try:
            if not os.path.exists(packages_txt) or os.path.getmtime(packages_txt) < os.path.getmtime(packages_gz):
                with gzip.open(packages_gz, "rb") as src, open(packages_txt, "wb") as dst:
                    shutil.copyfileobj(src, dst)
            break
        except (OSError, EOFError) as exc:
            if attempt == 1:
                raise RuntimeError(f"Failed to unpack cached Debian package index: {exc}") from exc
            print_warning(f"WARNING: Cached Debian package index is corrupt, re-downloading: {exc}")
            for stale_path in (packages_gz, packages_gz + ".part", packages_txt):
                if os.path.exists(stale_path):
                    os.remove(stale_path)

    with open(packages_txt, "r", encoding="utf-8", errors="replace") as f:
        index = parse_debian_packages_metadata(f.read())

    return base_url, index

def normalize_dependency_name(token):
    """Extract the package name from a Debian dependency token."""
    token = token.strip()
    if not token:
        return ""
    token = token.split("|", 1)[0].strip()
    token = re.sub(r"\s*\(.*?\)", "", token).strip()
    token = re.sub(r":[A-Za-z0-9_-]+$", "", token).strip()
    token = re.sub(r"\[.*?\]", "", token).strip()
    return token

def resolve_bootstrap_requested_packages(index, requested_patterns):
    """Resolve manifest entries to concrete Debian package names."""
    resolved = set()
    available_names = sorted(index)
    for pattern in requested_patterns:
        if any(ch in pattern for ch in "*?["):
            matches = [name for name in available_names if fnmatch.fnmatch(name, pattern)]
            if not matches:
                raise RuntimeError(f"Bootstrap manifest pattern matched no Debian packages: {pattern}")
            resolved.update(matches)
        else:
            if pattern not in index:
                raise RuntimeError(f"Bootstrap manifest package not found in Debian metadata: {pattern}")
            resolved.add(pattern)
    return sorted(resolved)

def resolve_bootstrap_dependency_closure(index, requested_packages):
    """Resolve Depends/Pre-Depends recursively for a set of Debian packages."""
    resolved = set()
    queue = list(requested_packages)

    while queue:
        package_name = queue.pop()
        if package_name in resolved or package_name not in index:
            continue
        resolved.add(package_name)
        entry = index[package_name]
        for field in ("Pre-Depends", "Depends"):
            raw_value = entry.get(field, "")
            if not raw_value:
                continue
            for dep_token in raw_value.split(","):
                dep_name = normalize_dependency_name(dep_token)
                if dep_name and dep_name in index and dep_name not in resolved:
                    queue.append(dep_name)

    return sorted(resolved)

def extract_deb_to_dir(deb_path, dest_dir):
    """Extract a .deb into a destination directory."""
    os.makedirs(dest_dir, exist_ok=True)
    result = subprocess.run(
        ["dpkg-deb", "-x", deb_path, dest_dir],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to extract {deb_path}: {result.stderr.strip()}")

def load_bootstrap_stage_progress(progress_path):
    """Load resumable bootstrap stage progress from disk."""
    if not os.path.exists(progress_path):
        return {}
    try:
        with open(progress_path, "r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}

def save_bootstrap_stage_progress(progress_path, payload):
    """Persist bootstrap stage progress atomically."""
    temp_path = progress_path + ".tmp"
    with open(temp_path, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    os.replace(temp_path, progress_path)

def get_bootstrap_stage_metadata_paths(stage_dir):
    """Store bootstrap bookkeeping outside the staged filesystem tree."""
    stage_name = os.path.basename(stage_dir.rstrip(os.sep))
    safe_stage_name = re.sub(r"[^A-Za-z0-9._-]+", "_", stage_name)
    metadata_dir = os.path.join(OUTPUT_DIR, "bootstrap-stage-state")
    os.makedirs(metadata_dir, exist_ok=True)
    return (
        os.path.join(metadata_dir, f"{safe_stage_name}.plan.json"),
        os.path.join(metadata_dir, f"{safe_stage_name}.progress.json"),
    )

def bootstrap_debian_stage(stage_dir, package_names, package_index, base_url):
    """Populate a stage directory from Debian .deb packages with resume support."""
    stage_name = os.path.basename(stage_dir)
    plan_path, progress_path = get_bootstrap_stage_metadata_paths(stage_dir)
    legacy_plan_path = os.path.join(stage_dir, ".bootstrap-plan.json")
    legacy_progress_path = os.path.join(stage_dir, ".bootstrap-progress.json")
    desired_plan = {"packages": package_names}
    expected_set = set(package_names)

    if os.path.exists(stage_dir):
        existing_plan = load_bootstrap_stage_progress(plan_path)
        if not existing_plan and os.path.exists(legacy_plan_path):
            existing_plan = load_bootstrap_stage_progress(legacy_plan_path)
        if existing_plan.get("packages") != package_names:
            print_warning(f"WARNING: Bootstrap plan changed for {stage_name}; resetting staged directory.")
            shutil.rmtree(stage_dir)
    os.makedirs(stage_dir, exist_ok=True)

    existing_progress = load_bootstrap_stage_progress(progress_path)
    if not existing_progress and os.path.exists(legacy_progress_path):
        existing_progress = load_bootstrap_stage_progress(legacy_progress_path)
    completed = set(existing_progress.get("completed", [])) & expected_set
    save_bootstrap_stage_progress(plan_path, desired_plan)
    save_bootstrap_stage_progress(
        progress_path,
        {
            "stage": stage_name,
            "total": len(package_names),
            "completed": sorted(completed),
        },
    )
    for stale_path in (legacy_plan_path, legacy_progress_path):
        if os.path.exists(stale_path):
            os.remove(stale_path)

    if completed:
        print_info(f"[*] Resuming {stage_name} from cache: {len(completed)}/{len(package_names)} packages already staged.")

    total_packages = len(package_names)
    for index, package_name in enumerate(package_names, 1):
        entry = package_index.get(package_name)
        if not entry:
            raise RuntimeError(f"Bootstrap package '{package_name}' is missing from Debian metadata")
        filename = entry.get("Filename")
        if not filename:
            raise RuntimeError(f"Bootstrap package '{package_name}' is missing a Filename entry")
        deb_url = urljoin(base_url, filename)
        deb_path = os.path.join(BOOTSTRAP_CACHE_DIR, filename)
        fetch_url_cached(
            deb_url,
            deb_path,
            label=f"{stage_name} [{index}/{total_packages}] {package_name}",
        )
        if package_name in completed:
            continue
        print_info(f"[*] Extracting {stage_name} [{index}/{total_packages}] {package_name}...")
        try:
            extract_deb_to_dir(deb_path, stage_dir)
        except RuntimeError as exc:
            print_warning(f"WARNING: Cached package for {package_name} looks invalid, re-fetching once: {exc}")
            for stale_path in (deb_path, deb_path + ".part"):
                if os.path.exists(stale_path):
                    os.remove(stale_path)
            fetch_url_cached(
                deb_url,
                deb_path,
                label=f"{stage_name} [{index}/{total_packages}] {package_name} (retry)",
            )
            extract_deb_to_dir(deb_path, stage_dir)
        completed.add(package_name)
        save_bootstrap_stage_progress(
            progress_path,
            {
                "stage": stage_name,
                "total": total_packages,
                "completed": sorted(completed),
            },
        )

    if os.path.exists(progress_path):
        os.remove(progress_path)

def ensure_debian_bootstrap():
    """Ensure bootstrap_rootfs and build_sysroot are seeded from Debian packages."""
    runtime_stamp = os.path.join(BOOTSTRAP_ROOTFS_DIR, ".bootstrap-complete")
    sysroot_stamp = os.path.join(BUILD_SYSROOT_DIR, ".bootstrap-complete")

    base_url, package_index = load_debian_package_index()
    runtime_requests = read_manifest_lines(BOOTSTRAP_RUNTIME_MANIFEST)
    toolchain_requests = read_manifest_lines(BOOTSTRAP_TOOLCHAIN_MANIFEST)

    runtime_seed = resolve_bootstrap_requested_packages(package_index, runtime_requests)
    toolchain_seed = resolve_bootstrap_requested_packages(package_index, toolchain_requests)
    runtime_packages = resolve_bootstrap_dependency_closure(package_index, runtime_seed)
    build_sysroot_packages = resolve_bootstrap_dependency_closure(package_index, runtime_seed + toolchain_seed)

    desired_runtime_stamp = "\n".join(runtime_packages) + "\n"
    desired_sysroot_stamp = "\n".join(build_sysroot_packages) + "\n"

    runtime_stage_ready = (
        os.path.isdir(BOOTSTRAP_ROOTFS_DIR)
        and os.path.exists(runtime_stamp)
        and open(runtime_stamp, "r").read() == desired_runtime_stamp
    )
    sysroot_stage_ready = (
        os.path.isdir(BUILD_SYSROOT_DIR)
        and os.path.exists(sysroot_stamp)
        and open(sysroot_stamp, "r").read() == desired_sysroot_stamp
    )
    if runtime_stage_ready and sysroot_stage_ready:
        return

    print_section("\n=== Bootstrapping Debian Base Stages ===")

    print_info(f"[*] Seeding bootstrap_rootfs with {len(runtime_packages)} Debian packages...")
    bootstrap_debian_stage(BOOTSTRAP_ROOTFS_DIR, runtime_packages, package_index, base_url)
    with open(runtime_stamp, "w") as f:
        f.write(desired_runtime_stamp)

    print_info(f"[*] Seeding build_sysroot with {len(build_sysroot_packages)} Debian packages...")
    bootstrap_debian_stage(BUILD_SYSROOT_DIR, build_sysroot_packages, package_index, base_url)
    with open(sysroot_stamp, "w") as f:
        f.write(desired_sysroot_stamp)

def prepare_stage_dirs():
    """Ensure the staged build directories exist and are bootstrapped."""
    cleanup_transient_workspace_artifacts(report=True)
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    ensure_debian_bootstrap()

def prepare_build_system_helpers():
    """Rebuild the local shim/wrapper helpers so env changes take effect immediately."""
    print_section("\n=== Preparing Build Helpers ===")
    result = subprocess.run(
        ["make", "-C", BUILD_SYSTEM_DIR],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print_error("FATAL: Failed to build build_system helpers.")
        if result.stdout:
            print(result.stdout.rstrip())
        if result.stderr:
            print(result.stderr.rstrip())
        return False
    print_success("  ✓ build_system wrappers rebuilt")
    return True

def assemble_final_rootfs():
    """Assemble the final runtime rootfs from bootstrap_rootfs plus the build sysroot."""
    print_section("\n=== Assembling Final Rootfs ===")
    if os.path.exists(FINAL_ROOTFS_DIR):
        shutil.rmtree(FINAL_ROOTFS_DIR)

    shutil.copytree(BOOTSTRAP_ROOTFS_DIR, FINAL_ROOTFS_DIR, symlinks=True)
    for entry in sorted(os.listdir(BUILD_SYSROOT_DIR)):
        overlay_rootfs_entry(
            os.path.join(BUILD_SYSROOT_DIR, entry),
            os.path.join(FINAL_ROOTFS_DIR, entry),
        )
    for stamp_name in (".bootstrap-complete",):
        stamp_path = os.path.join(FINAL_ROOTFS_DIR, stamp_name)
        if os.path.exists(stamp_path):
            os.remove(stamp_path)
    for leaked_path in (".bootstrap-plan.json", ".bootstrap-progress.json", "init"):
        leaked_abs_path = os.path.join(FINAL_ROOTFS_DIR, leaked_path)
        if os.path.lexists(leaked_abs_path):
            remove_path(leaked_abs_path)
    normalize_rootfs_multiarch_layout(root_dir=FINAL_ROOTFS_DIR, report=True)

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

def expand_manifest_artifact_paths(artifact, root_dir=None):
    """Return candidate paths for a manifest artifact, supporting exact paths and globs."""
    root_dir = root_dir or ROOTFS_DIR
    project_relative = artifact.lstrip("/") if artifact.startswith("/") else artifact
    rootfs_pattern = os.path.join(root_dir, project_relative)
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

def fallback_manifest_artifact_paths(artifact, root_dir=None):
    """Return smart fallback candidates for manifest entries that describe shared libraries."""
    root_dir = root_dir or ROOTFS_DIR
    project_relative = artifact.lstrip("/") if artifact.startswith("/") else artifact
    rootfs_path = os.path.join(root_dir, project_relative)
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

def artifact_exists_from_manifest(artifact, root_dir=None):
    """Check whether a manifest artifact exists, allowing glob patterns."""
    root_dir = root_dir or ROOTFS_DIR
    matched_paths = expand_manifest_artifact_paths(artifact, root_dir=root_dir)
    if not matched_paths:
        matched_paths = fallback_manifest_artifact_paths(artifact, root_dir=root_dir)
    if not matched_paths:
        return False

    for path in matched_paths:
        if os.path.exists(resolve_rootfs_path(root_dir, path)):
            return True
    return False

def get_missing_manifest_artifacts(pkg_name, root_dir=None):
    """Return missing manifest entries for a package."""
    if pkg_name not in PACKAGE_MANIFESTS:
        return []

    missing_artifacts = []
    for artifact in PACKAGE_MANIFESTS[pkg_name]:
        if not artifact_exists_from_manifest(artifact, root_dir=root_dir):
            missing_artifacts.append(artifact)
    return missing_artifacts

def collect_package_artifact_paths(pkg_name, root_dir=None):
    """Collect concrete existing filesystem paths from a package manifest."""
    root_dir = root_dir or ROOTFS_DIR
    if pkg_name not in PACKAGE_MANIFESTS:
        return []

    collected = []
    seen = set()
    for artifact in PACKAGE_MANIFESTS[pkg_name]:
        candidates = expand_manifest_artifact_paths(artifact, root_dir=root_dir)
        if not candidates:
            candidates = fallback_manifest_artifact_paths(artifact, root_dir=root_dir)
        for path in candidates:
            if not os.path.exists(path):
                continue
            real_path = resolve_rootfs_path(root_dir, path)
            if real_path in seen:
                continue
            seen.add(real_path)
            collected.append(real_path)
    return collected

def get_dbus_runtime_abi_issues(root_dir=None):
    """Return DBus runtime/library ABI mismatches inside the staged rootfs."""
    root_dir = root_dir or ROOTFS_DIR
    dbus_launch_path = os.path.join(root_dir, "usr", "bin", "dbus-launch")
    dbus_lib_path = os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu", "libdbus-1.so.3")

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
        current = resolve_rootfs_path(rootfs_dir, to_process.pop())
        if current in visited:
            continue
        visited.add(current)
        current_rpaths = get_elf_rpaths(current)

        for lib_filename in get_elf_needed(current):
            candidate = find_rootfs_library(
                rootfs_dir,
                lib_filename,
                current_path=current,
                rpaths=current_rpaths,
            )
            if not candidate:
                current_rel = os.path.relpath(current, rootfs_dir).replace(os.sep, "/")
                issues.append(f"{current_rel} is missing runtime dependency {lib_filename}")
                continue
            to_process.append(candidate)

    return issues

def get_glib_runtime_issues(root_dir=None):
    """Return GLib/GIO runtime mismatches inside the staged rootfs."""
    rootfs_dir = root_dir or ROOTFS_DIR
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

def get_libxml2_runtime_issues(root_dir=None):
    """Return libxml2 runtime mismatches inside the staged rootfs."""
    rootfs_dir = root_dir or ROOTFS_DIR
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

def get_shared_mime_info_runtime_issues(root_dir=None):
    """Return shared-mime-info runtime mismatches inside the staged rootfs."""
    rootfs_dir = root_dir or ROOTFS_DIR
    update_mime_path = os.path.join(rootfs_dir, "usr", "bin", "update-mime-database")
    if not os.path.exists(update_mime_path):
        return []

    return collect_missing_runtime_deps(rootfs_dir, [update_mime_path])

def get_util_linux_runtime_issues(root_dir=None):
    """Return util-linux ABI/runtime mismatches inside the staged rootfs."""
    rootfs_dir = root_dir or ROOTFS_DIR
    libmount_path = os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu", "libmount.so.1")
    if not os.path.exists(libmount_path):
        return []

    libmount_real = os.path.realpath(libmount_path)
    return collect_missing_runtime_deps(
        rootfs_dir,
        [
            os.path.join(rootfs_dir, "bin", "mount"),
            os.path.join(rootfs_dir, "bin", "umount"),
            os.path.join(rootfs_dir, "sbin", "switch_root"),
            libmount_real,
        ],
    )

def find_existing_rootfs_relpath(root_dir, relpaths):
    """Return the first existing rootfs-relative path from the given candidates."""
    for relpath in relpaths:
        if os.path.exists(os.path.join(root_dir, relpath)):
            return relpath
    return None


def get_selinux_type(root_dir):
    """Return the configured SELinux policy store name for a staged rootfs."""
    config_path = os.path.join(root_dir, "etc", "selinux", "config")
    if not os.path.exists(config_path):
        return "default"

    try:
        with open(config_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("SELINUXTYPE="):
                    value = stripped.split("=", 1)[1].strip()
                    if value:
                        return value
    except OSError:
        pass

    return "default"


def materialize_selinux_policy_store(root_dir=None):
    """Best-effort offline SELinux policy build for the staged rootfs."""
    rootfs_dir = root_dir or FINAL_ROOTFS_DIR
    selinux_type = get_selinux_type(rootfs_dir)
    contexts_dir = os.path.join(rootfs_dir, "etc", "selinux", selinux_type, "contexts", "files")
    policy_dir = os.path.join(rootfs_dir, "etc", "selinux", selinux_type, "policy")
    existing_file_contexts = glob.glob(os.path.join(contexts_dir, "file_contexts*"))
    existing_policy = glob.glob(os.path.join(policy_dir, "policy.*"))
    if existing_file_contexts and existing_policy:
        return True

    modules_manifest = os.path.join(rootfs_dir, "usr", "share", "selinux", selinux_type, ".modules")
    semanage_conf = os.path.join(rootfs_dir, "etc", "selinux", "semanage.conf")
    semodule_rel = find_existing_rootfs_relpath(rootfs_dir, ["usr/sbin/semodule", "sbin/semodule"])
    setfiles_rel = find_existing_rootfs_relpath(rootfs_dir, ["usr/sbin/setfiles", "sbin/setfiles"])
    sefcontext_compile_rel = find_existing_rootfs_relpath(
        rootfs_dir,
        ["usr/sbin/sefcontext_compile", "sbin/sefcontext_compile"],
    )
    hll_compiler_dir = os.path.join(rootfs_dir, "usr", "libexec", "selinux", "hll")

    if not all(
        [
            os.path.exists(modules_manifest),
            os.path.exists(semanage_conf),
            semodule_rel,
            setfiles_rel,
            sefcontext_compile_rel,
            os.path.isdir(hll_compiler_dir),
        ]
    ):
        return False

    runtime_lib_dirs = []
    for path in (
        os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu"),
        os.path.join(rootfs_dir, "lib", "x86_64-linux-gnu"),
        os.path.join(rootfs_dir, "usr", "lib64"),
        os.path.join(rootfs_dir, "lib64"),
    ):
        if os.path.isdir(path):
            runtime_lib_dirs.append(os.path.realpath(path))
    if not runtime_lib_dirs:
        return False

    print_info("[*] Materializing staged SELinux policy store...")

    with tempfile.TemporaryDirectory(prefix="geminios-selinux-") as tmpdir:
        lib_path = ":".join(dict.fromkeys(runtime_lib_dirs))
        setfiles_wrapper = os.path.join(tmpdir, "setfiles-wrapper.sh")
        sefcontext_wrapper = os.path.join(tmpdir, "sefcontext-compile-wrapper.sh")
        staged_setfiles = rootfs_abspath(rootfs_dir, setfiles_rel)
        staged_sefcontext = rootfs_abspath(rootfs_dir, sefcontext_compile_rel)

        for wrapper_path, target_binary in (
            (setfiles_wrapper, staged_setfiles),
            (sefcontext_wrapper, staged_sefcontext),
        ):
            with open(wrapper_path, "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\n")
                f.write(f"export LD_LIBRARY_PATH={shlex.quote(lib_path)}\n")
                f.write(f"exec {shlex.quote(target_binary)} \"$@\"\n")
            os.chmod(wrapper_path, 0o755)

        with open(semanage_conf, "r", encoding="utf-8", errors="replace") as f:
            semanage_text = f.read().rstrip() + "\n"
        semanage_text += f"compiler-directory = {hll_compiler_dir}\n"
        semanage_text += "[setfiles]\n"
        semanage_text += f"path = {setfiles_wrapper}\n"
        semanage_text += "args = -q -c $@ $<\n"
        semanage_text += "[end]\n"
        semanage_text += "[sefcontext_compile]\n"
        semanage_text += f"path = {sefcontext_wrapper}\n"
        semanage_text += "args = $@\n"
        semanage_text += "[end]\n"

        temp_conf_path = os.path.join(tmpdir, "semanage.conf")
        with open(temp_conf_path, "w", encoding="utf-8") as f:
            f.write(semanage_text)

        module_args = []
        for module_name in read_manifest_lines(modules_manifest):
            module_path = os.path.join(rootfs_dir, "usr", "share", "selinux", selinux_type, f"{module_name}.pp.bz2")
            if os.path.exists(module_path):
                module_args.append(f"-i{module_path}")

        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = lib_path
        result = run_staged_binary_command(
            rootfs_dir,
            semodule_rel,
            ["-n", "-s", selinux_type, "-p", rootfs_dir, "-g", temp_conf_path, "-X", "100", *module_args],
            env=env,
        )
        if result.returncode != 0:
            stderr = (result.stderr or "").strip().splitlines()
            summary = stderr[-1] if stderr else f"exit {result.returncode}"
            print_warning(f"  SELinux policy materialization reported: {summary}")

    generated_policy_paths = glob.glob(
        os.path.join(rootfs_dir, "var", "lib", "selinux", "final", selinux_type, "policy", "policy.*")
    )
    generated_file_contexts = glob.glob(
        os.path.join(rootfs_dir, "var", "lib", "selinux", "final", selinux_type, "contexts", "files", "file_contexts*")
    )

    if generated_policy_paths:
        os.makedirs(policy_dir, exist_ok=True)
        for src_path in generated_policy_paths:
            shutil.copy2(src_path, os.path.join(policy_dir, os.path.basename(src_path)))

    if generated_file_contexts:
        os.makedirs(contexts_dir, exist_ok=True)
        for src_path in generated_file_contexts:
            shutil.copy2(src_path, os.path.join(contexts_dir, os.path.basename(src_path)))

    staged_ok = bool(glob.glob(os.path.join(contexts_dir, "file_contexts*"))) and bool(
        glob.glob(os.path.join(policy_dir, "policy.*"))
    )
    if staged_ok:
        print_success("  ✓ Staged SELinux policy artifacts generated")
    return staged_ok

def get_selinux_runtime_issues(root_dir=None):
    """Return SELinux policy/runtime mismatches inside the staged rootfs."""
    rootfs_dir = root_dir or ROOTFS_DIR
    issues = []

    config_path = os.path.join(rootfs_dir, "etc", "selinux", "config")
    if not os.path.exists(config_path):
        return ["SELinux config is missing: etc/selinux/config"]

    with open(config_path, "r", encoding="utf-8", errors="replace") as f:
        config_text = f.read()
    if "SELINUX=" not in config_text:
        issues.append("etc/selinux/config does not declare SELINUX=")
    if "SELINUXTYPE=default" not in config_text:
        issues.append("etc/selinux/config should pin SELINUXTYPE=default")

    required_bins = {
        "load_policy": ["usr/sbin/load_policy", "sbin/load_policy"],
        "setfiles": ["usr/sbin/setfiles", "sbin/setfiles"],
        "restorecon": ["usr/sbin/restorecon", "sbin/restorecon"],
        "setenforce": ["usr/sbin/setenforce", "sbin/setenforce"],
    }
    for label, candidates in required_bins.items():
        if not find_existing_rootfs_relpath(rootfs_dir, candidates):
            issues.append(f"SELinux helper missing from staged rootfs: {label}")

    required_libs = [
        "usr/lib/x86_64-linux-gnu/libselinux.so.1",
        "usr/lib/x86_64-linux-gnu/libsepol.so.2",
    ]
    for relpath in required_libs:
        if not os.path.exists(os.path.join(rootfs_dir, relpath)):
            issues.append(f"SELinux runtime library missing: {relpath}")

    file_context_candidates = [
        os.path.join(rootfs_dir, "etc", "selinux", "default", "contexts", "files", "file_contexts"),
        os.path.join(rootfs_dir, "etc", "selinux", "targeted", "contexts", "files", "file_contexts"),
    ]
    if not any(os.path.exists(path) for path in file_context_candidates):
        issues.append("SELinux file contexts are missing from /etc/selinux")

    policy_candidates = (
        glob.glob(os.path.join(rootfs_dir, "etc", "selinux", "default", "policy", "policy.*"))
        + glob.glob(os.path.join(rootfs_dir, "etc", "selinux", "targeted", "policy", "policy.*"))
    )
    if not policy_candidates:
        issues.append("SELinux binary policy store is missing from /etc/selinux")

    return issues

def extract_glibc_release_version(binary_path):
    """Return the glibc release version string embedded in a runtime object."""
    result = subprocess.run(
        ["strings", "-a", binary_path],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None

    for line in result.stdout.splitlines():
        match = re.search(r"release version ([0-9][0-9.]+)", line)
        if match:
            return match.group(1)
    return None

def get_glibc_runtime_issues(root_dir=None):
    """Return staged glibc loader/runtime mismatches inside the rootfs."""
    rootfs_dir = root_dir or ROOTFS_DIR
    libc_path = os.path.join(rootfs_dir, "lib", "x86_64-linux-gnu", "libc.so.6")
    loader_path = os.path.join(rootfs_dir, "lib", "x86_64-linux-gnu", "ld-linux-x86-64.so.2")

    if not (os.path.exists(libc_path) and os.path.exists(loader_path)):
        return []

    issues = []
    libc_version = extract_glibc_release_version(libc_path)
    loader_version = extract_glibc_release_version(loader_path)
    if libc_version and loader_version and libc_version != loader_version:
        issues.append(
            f"glibc runtime mismatch: libc.so.6 is {libc_version} but ld-linux-x86-64.so.2 is {loader_version}"
        )

    library_path = ":".join(
        [
            os.path.join(rootfs_dir, "lib", "x86_64-linux-gnu"),
            os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu"),
        ]
    )
    result = subprocess.run(
        [loader_path, "--library-path", library_path, libc_path],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        stderr = (result.stderr or "").strip().splitlines()
        stdout = (result.stdout or "").strip().splitlines()
        detail = stderr[-1] if stderr else (stdout[-1] if stdout else f"exit code {result.returncode}")
        issues.append(f"staged glibc self-test failed: {detail}")

    return issues

def iter_pkgconfig_metadata_paths(root_dir=None):
    """Yield pkg-config metadata paths inside the staged rootfs."""
    root_dir = root_dir or ROOTFS_DIR
    search_roots = [
        os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu", "pkgconfig"),
        os.path.join(root_dir, "usr", "share", "pkgconfig"),
    ]
    paths = set()
    for search_root in search_roots:
        if not os.path.isdir(search_root):
            continue
        paths.update(glob.glob(os.path.join(search_root, "*.pc")))
    return sorted(paths)

def collapse_pkgconfig_staged_path(path_text):
    """Rewrite absolute staged paths back into in-root pkg-config paths."""
    normalized_path = path_text.rstrip("/")
    for stage_root in PKGCONFIG_STAGE_ROOTS:
        stage_root = stage_root.rstrip("/")
        if not stage_root:
            continue
        prefix = stage_root + os.sep
        if normalized_path.startswith(prefix):
            rel_path = os.path.relpath(normalized_path, stage_root).replace(os.sep, "/")
            return "/" + rel_path.lstrip("/")
    return normalized_path

def normalize_pkgconfig_assignment_value(name, value, is_multiarch_pkgconfig):
    """Normalize pkg-config variable assignments back into Debian multiarch form."""
    normalized = value
    for legacy_prefix in (
        "${exec_prefix}/lib64",
        "${exec_prefix}/lib",
        "${prefix}/lib64",
        "${prefix}/lib",
        "/usr/lib64",
        "/usr/lib",
    ):
        if name == "libdir" and normalized == legacy_prefix:
            normalized = PKGCONFIG_CANONICAL_LIBDIR
            break

    normalized = normalized.replace("${exec_prefix}/lib64/", PKGCONFIG_CANONICAL_LIBDIR + "/")
    normalized = normalized.replace("${prefix}/lib64/", PKGCONFIG_CANONICAL_LIBDIR + "/")
    normalized = normalized.replace("/usr/lib64/", PKGCONFIG_CANONICAL_LIBDIR + "/")

    if is_multiarch_pkgconfig and name == "libdir" and normalized in PKGCONFIG_LEGACY_LIBDIR_VALUES:
        normalized = PKGCONFIG_CANONICAL_LIBDIR

    return normalized

def split_pkgconfig_tokens(value):
    """Split pkg-config flag fields without crashing on malformed metadata."""
    try:
        return shlex.split(value)
    except ValueError:
        return value.split()

def normalize_pkgconfig_lib_search_path(path_text):
    """Normalize pkg-config library search paths to the canonical libdir variable."""
    normalized = collapse_pkgconfig_staged_path(path_text.strip())
    if normalized in PKGCONFIG_LEGACY_LIBDIR_VALUES or normalized == "${libdir}":
        return "${libdir}"
    return normalized

def normalize_pkgconfig_include_search_path(path_text):
    """Normalize pkg-config include search paths to the canonical include variable."""
    normalized = collapse_pkgconfig_staged_path(path_text.strip())
    if normalized in {"/usr/include", "${exec_prefix}/include", "${prefix}/include", "${includedir}"}:
        return "${includedir}"
    return normalized

def normalize_pkgconfig_flag_field(field_name, value):
    """Normalize pkg-config Libs/Cflags fields to avoid staged path leakage."""
    tokens = split_pkgconfig_tokens(value)
    normalized_tokens = []
    seen_tokens = set()

    for token in tokens:
        if token.startswith("--sysroot="):
            continue

        if token.startswith("-L"):
            search_path = normalize_pkgconfig_lib_search_path(token[2:])
            if not search_path:
                continue
            token = f"-L{search_path}"
        elif token.startswith("-I"):
            include_path = normalize_pkgconfig_include_search_path(token[2:])
            if not include_path:
                continue
            token = f"-I{include_path}"
        elif any(marker and marker in token for marker in PKGCONFIG_LEAK_MARKERS):
            continue

        if token in seen_tokens:
            continue
        seen_tokens.add(token)
        normalized_tokens.append(token)

    if normalized_tokens:
        return f"{field_name}: {' '.join(normalized_tokens)}"
    return f"{field_name}:"

def get_pkgconfig_metadata_issues(path, root_dir=None):
    """Return pkg-config layout issues for a single .pc file."""
    root_dir = root_dir or ROOTFS_DIR
    rel_path = os.path.relpath(path, root_dir).replace(os.sep, "/")
    issues = []
    try:
        with open(path, "r") as f:
            data = f.read()
    except OSError as exc:
        return [f"failed to inspect pkg-config metadata {rel_path}: {exc}"]

    if any(pattern in data for pattern in ("/usr/lib64", "${exec_prefix}/lib64", "${prefix}/lib64")):
        issues.append(f"{rel_path} still points pkg-config consumers at /usr/lib64")

    if any(marker and marker in data for marker in PKGCONFIG_LEAK_MARKERS) or "--sysroot=" in data:
        issues.append(f"{rel_path} leaks staged build paths into pkg-config metadata")

    if rel_path.startswith(PKGCONFIG_MULTIARCH_DIR.replace(os.sep, "/")):
        if re.search(r"^libdir=(/usr/lib|\$\{exec_prefix\}/lib|\$\{prefix\}/lib)\s*$", data, re.MULTILINE):
            issues.append(f"{rel_path} still points pkg-config consumers at /usr/lib instead of Debian multiarch")
        if re.search(
            r"^Libs(?:\.private)?:.*(?:-L/usr/lib(?:\s|$)|-L/usr/lib64(?:\s|$)|-L/lib64(?:\s|$)|-L/lib/x86_64-linux-gnu(?:\s|$))",
            data,
            re.MULTILINE,
        ):
            issues.append(f"{rel_path} still injects non-multiarch library search paths into pkg-config consumers")

    return issues

def get_all_pkgconfig_layout_issues(root_dir=None):
    """Return pkg-config metadata issues across the entire staged rootfs."""
    root_dir = root_dir or ROOTFS_DIR
    issues = []
    for path in iter_pkgconfig_metadata_paths(root_dir=root_dir):
        issues.extend(get_pkgconfig_metadata_issues(path, root_dir=root_dir))
    return issues

def iter_libtool_archive_paths(root_dir=None):
    """Yield installed libtool archive metadata inside the staged rootfs."""
    root_dir = root_dir or ROOTFS_DIR
    search_roots = [
        os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu"),
        os.path.join(root_dir, "lib", "x86_64-linux-gnu"),
        os.path.join(root_dir, "usr", "lib"),
        os.path.join(root_dir, "lib"),
    ]
    paths = set()
    for search_root in search_roots:
        if not os.path.isdir(search_root):
            continue
        paths.update(glob.glob(os.path.join(search_root, "*.la")))
    return sorted(paths)

def libtool_dependency_token_to_link_flag(token):
    """Collapse a concrete library path into a generic -lfoo linker flag."""
    basename = os.path.basename(token)
    if not basename.startswith("lib"):
        return None
    if basename.endswith(".la"):
        return f"-l{basename[3:-3]}"
    if basename.endswith(".a"):
        return f"-l{basename[3:-2]}"
    if ".so" in basename:
        return f"-l{basename[3:].split('.so', 1)[0]}"
    return None

def normalize_libtool_dependency_token(token):
    """Normalize staged libtool dependency metadata so later relinks stay target-clean."""
    raw_token = token.strip()
    if not raw_token:
        return None

    if raw_token.startswith("--sysroot="):
        return None

    if raw_token.startswith("-L"):
        search_path = collapse_pkgconfig_staged_path(raw_token[2:])
        if search_path in PKGCONFIG_LEGACY_LIBDIR_VALUES or search_path in {
            PKGCONFIG_CANONICAL_LIBDIR,
            "/lib/x86_64-linux-gnu",
            "/usr/lib",
            "/lib",
            "/usr/lib64",
            "/lib64",
            "${libdir}",
        }:
            return None
        if any(marker and marker in search_path for marker in PKGCONFIG_LEAK_MARKERS):
            return None
        return f"-L{search_path}"

    normalized = collapse_pkgconfig_staged_path(raw_token)

    if normalized.startswith("/"):
        link_flag = libtool_dependency_token_to_link_flag(normalized)
        if link_flag:
            return link_flag
        if any(marker and marker in normalized for marker in PKGCONFIG_LEAK_MARKERS):
            return None

    if any(marker and marker in normalized for marker in PKGCONFIG_LEAK_MARKERS):
        return None

    return normalized

def normalize_libtool_dependency_libs(value):
    """Normalize libtool dependency_libs without dropping real link requirements."""
    tokens = split_pkgconfig_tokens(value)
    normalized_tokens = []
    seen_tokens = set()

    for token in tokens:
        normalized = normalize_libtool_dependency_token(token)
        if not normalized or normalized in seen_tokens:
            continue
        seen_tokens.add(normalized)
        normalized_tokens.append(normalized)

    return " ".join(normalized_tokens)

def normalize_libtool_archive_metadata(root_dir=None, report=False):
    """Scrub staged libtool archives so they do not leak staged paths into later builds."""
    root_dir = root_dir or ROOTFS_DIR
    rewritten_paths = []

    for path in iter_libtool_archive_paths(root_dir=root_dir):
        try:
            with open(path, "r") as f:
                lines = f.readlines()
        except OSError:
            continue

        new_lines = []
        changed = False
        for line in lines:
            stripped = line.rstrip("\n")
            match = re.match(r"^([A-Za-z_]+)='(.*)'$", stripped)
            if not match:
                new_lines.append(line)
                continue

            name, value = match.groups()
            new_value = value
            if name == "dependency_libs":
                new_value = normalize_libtool_dependency_libs(value)
            elif name == "libdir":
                new_value = collapse_pkgconfig_staged_path(value)
                if new_value in PKGCONFIG_LEGACY_LIBDIR_VALUES:
                    new_value = PKGCONFIG_CANONICAL_LIBDIR

            new_line = f"{name}='{new_value}'\n"
            if new_line != line:
                changed = True
            new_lines.append(new_line)

        if not changed:
            continue

        with open(path, "w") as f:
            f.writelines(new_lines)
        rewritten_paths.append(os.path.relpath(path, root_dir).replace(os.sep, "/"))

    if report and rewritten_paths:
        print_info("[*] Normalizing staged libtool metadata...")
        for rel_path in rewritten_paths[:12]:
            print_info(f"  Rewrote {rel_path}")
        if len(rewritten_paths) > 12:
            print_info(f"  Rewrote {len(rewritten_paths) - 12} additional libtool archive files.")

    return rewritten_paths

def normalize_pkgconfig_metadata(root_dir=None, report=False):
    """Scrub staged pkg-config metadata back into Debian multiarch form."""
    root_dir = root_dir or ROOTFS_DIR
    multiarch_pkgconfig_dir = os.path.join(root_dir, PKGCONFIG_MULTIARCH_DIR)
    rewritten_paths = []

    for path in iter_pkgconfig_metadata_paths(root_dir=root_dir):
        try:
            common_root = os.path.commonpath([multiarch_pkgconfig_dir, path])
        except ValueError:
            common_root = ""
        is_multiarch_pkgconfig = common_root == multiarch_pkgconfig_dir

        try:
            with open(path, "r") as f:
                lines = f.readlines()
        except OSError:
            continue

        new_lines = []
        changed = False
        for line in lines:
            stripped = line.rstrip("\n")
            assignment_match = re.match(r"^([A-Za-z][A-Za-z0-9_]*)=(.*)$", stripped)
            if assignment_match:
                name, value = assignment_match.groups()
                normalized_value = normalize_pkgconfig_assignment_value(
                    name,
                    value,
                    is_multiarch_pkgconfig=is_multiarch_pkgconfig,
                )
                new_line = f"{name}={normalized_value}\n"
            else:
                field_match = re.match(r"^(Libs(?:\.private)?|Cflags(?:\.private)?):(.*)$", stripped)
                if field_match:
                    field_name, value = field_match.groups()
                    new_line = normalize_pkgconfig_flag_field(field_name, value) + "\n"
                else:
                    new_line = line

            if new_line != line:
                changed = True
            new_lines.append(new_line)

        if not changed:
            continue

        with open(path, "w") as f:
            f.writelines(new_lines)
        rewritten_paths.append(os.path.relpath(path, root_dir).replace(os.sep, "/"))

    if report and rewritten_paths:
        print_info("[*] Normalizing staged pkg-config metadata...")
        for rel_path in rewritten_paths[:12]:
            print_info(f"  Rewrote {rel_path}")
        if len(rewritten_paths) > 12:
            print_info(f"  Rewrote {len(rewritten_paths) - 12} additional pkg-config files.")

    return rewritten_paths

def get_pkgconfig_layout_issues(pkg_name, root_dir=None):
    """Return pkg-config metadata issues that would leak non-Debian library paths."""
    root_dir = root_dir or ROOTFS_DIR
    issues = []
    for artifact in PACKAGE_MANIFESTS.get(pkg_name, []):
        if not artifact.endswith(".pc"):
            continue
        for path in expand_manifest_artifact_paths(artifact, root_dir=root_dir):
            if not os.path.exists(path):
                continue
            issues.extend(get_pkgconfig_metadata_issues(path, root_dir=root_dir))
    return issues

def get_openssl_runtime_issues(root_dir=None):
    """Return staged OpenSSL layout issues that break target consumers."""
    root_dir = root_dir or ROOTFS_DIR
    issues = []
    canonical_header_dir = os.path.join(root_dir, "usr", "include", "openssl")
    multiarch_header_dir = os.path.join(root_dir, "usr", "include", "x86_64-linux-gnu", "openssl")
    canonical_config = os.path.join(canonical_header_dir, "configuration.h")
    multiarch_config = os.path.join(multiarch_header_dir, "configuration.h")

    if os.path.lexists(multiarch_header_dir):
        if os.path.islink(multiarch_header_dir):
            target = os.readlink(multiarch_header_dir)
            if target != "../../openssl":
                issues.append(
                    "usr/include/x86_64-linux-gnu/openssl should symlink to ../../openssl"
                )
        elif os.path.exists(canonical_config) and os.path.exists(multiarch_config):
            try:
                if not filecmp.cmp(canonical_config, multiarch_config, shallow=False):
                    issues.append(
                        "usr/include/x86_64-linux-gnu/openssl/configuration.h conflicts with usr/include/openssl/configuration.h"
                    )
            except OSError as exc:
                issues.append(f"failed to compare OpenSSL configuration headers: {exc}")
    return issues

def get_python_runtime_issues(root_dir=None):
    """Return staged Python runtime issues that break target Python package builds."""
    root_dir = root_dir or ROOTFS_DIR
    python_candidates = [
        os.path.join(root_dir, "usr", "bin", "python3"),
        os.path.join(root_dir, "usr", "bin", "python3.11"),
    ]
    python_path = next((candidate for candidate in python_candidates if os.path.exists(candidate)), None)
    if not python_path:
        return []

    issues = []
    ok, detail = run_staged_binary_smoke_test(
        root_dir,
        os.path.relpath(python_path, root_dir).replace(os.sep, "/"),
        ["-c", 'import encodings, sysconfig; print("python-ok")'],
    )
    if not ok:
        issues.append(f"staged python self-test failed: {detail}")

    wrapper_path = os.path.join(ROOT_DIR, "build_system", "run_target_python.sh")
    if os.path.exists(wrapper_path):
        env = os.environ.copy()
        env["TARGET_SYSROOT"] = root_dir
        env.pop("LD_LIBRARY_PATH", None)
        env.pop("PYTHONHOME", None)
        env.pop("PYTHONPATH", None)
        result = subprocess.run(
            [wrapper_path, "-c", 'import encodings, sysconfig; print("python-wrapper-ok")'],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        if result.returncode != 0:
            stderr = (result.stderr or "").strip().splitlines()
            stdout = (result.stdout or "").strip().splitlines()
            detail = stderr[-1] if stderr else (stdout[-1] if stdout else f"exit code {result.returncode}")
            issues.append(f"run_target_python wrapper failed: {detail}")

    return issues

def get_dbus_helper_permission_issues(root_dir=None):
    """Return staged D-Bus helper permission issues."""
    root_dir = root_dir or ROOTFS_DIR
    helper_path = os.path.join(root_dir, DBUS_HELPER_REL_PATH)
    if not os.path.exists(helper_path):
        return []

    issues = []
    helper_stat = os.lstat(helper_path)
    helper_mode = stat.S_IMODE(helper_stat.st_mode)
    if helper_mode != DBUS_HELPER_REQUIRED_MODE:
        issues.append(
            f"{DBUS_HELPER_REL_PATH.replace(os.sep, '/')} should have mode {DBUS_HELPER_REQUIRED_MODE:o} "
            f"in the staged rootfs (found {helper_mode:o})"
        )
    return issues

def get_squashfs_metadata_overrides(root_dir=None):
    """Return SquashFS pseudo definitions for paths that need non-root group metadata."""
    root_dir = root_dir or FINAL_ROOTFS_DIR
    overrides = []

    helper_path = os.path.join(root_dir, DBUS_HELPER_REL_PATH)
    if os.path.exists(helper_path):
        overrides.append(
            (
                DBUS_HELPER_REL_PATH.replace(os.sep, "/"),
                DBUS_HELPER_REQUIRED_MODE,
                DBUS_HELPER_REQUIRED_UID,
                DBUS_HELPER_REQUIRED_GID,
            )
        )

    return overrides

def build_mksquashfs_metadata_args(root_dir=None):
    """Return shell-quoted mksquashfs pseudo-definition arguments."""
    overrides = get_squashfs_metadata_overrides(root_dir=root_dir)
    if not overrides:
        return ""

    args = ["-pseudo-override"]
    for rel_path, mode, uid, gid in overrides:
        pseudo_definition = f"{rel_path} m {mode:o} {uid} {gid}"
        args.append(f"-p {shlex.quote(pseudo_definition)}")
    return " " + " ".join(args)

def get_squashfs_metadata_issues(sfs_path, root_dir=None):
    """Return special metadata issues detected in a packed SquashFS image."""
    if not shutil.which("unsquashfs"):
        return []

    issues = []
    for rel_path, mode, uid, gid in get_squashfs_metadata_overrides(root_dir=root_dir):
        result = subprocess.run(
            ["unsquashfs", "-lln", sfs_path, rel_path],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or f"exit code {result.returncode}").strip().splitlines()
            issues.append(
                f"failed to inspect {rel_path} metadata inside {os.path.basename(sfs_path)}: "
                f"{detail[-1] if detail else f'exit code {result.returncode}'}"
            )
            continue

        helper_line = ""
        expected_suffix = f"squashfs-root/{rel_path}"
        for line in (result.stdout or "").splitlines():
            stripped = line.strip()
            if stripped.endswith(expected_suffix):
                helper_line = stripped
                break

        if not helper_line:
            issues.append(f"{rel_path} is missing from packed SquashFS image")
            continue

        expected_mode = stat.filemode(stat.S_IFREG | mode)
        expected_owner = f"{uid}/{gid}"
        if not helper_line.startswith(expected_mode) or f" {expected_owner} " not in helper_line:
            issues.append(
                f"{rel_path} should be packed as {expected_mode} {expected_owner}, "
                f"but SquashFS recorded: {helper_line}"
            )

    return issues

def get_package_verification_issues(pkg_name, root_dir=None):
    """Return manifest and semantic verification issues for a package."""
    issues = []
    issues.extend(f"missing artifact: {artifact}" for artifact in get_missing_manifest_artifacts(pkg_name, root_dir=root_dir))
    issues.extend(get_pkgconfig_layout_issues(pkg_name, root_dir=root_dir))

    if pkg_name == "glibc":
        issues.extend(get_glibc_runtime_issues(root_dir=root_dir))
    elif pkg_name == "python":
        issues.extend(get_python_runtime_issues(root_dir=root_dir))
    elif pkg_name == "openssl":
        issues.extend(get_openssl_runtime_issues(root_dir=root_dir))
    elif pkg_name == "dbus":
        issues.extend(get_dbus_runtime_abi_issues(root_dir=root_dir))
        issues.extend(get_dbus_helper_permission_issues(root_dir=root_dir))
    elif pkg_name == "glib":
        issues.extend(get_glib_runtime_issues(root_dir=root_dir))
    elif pkg_name == "libxml2":
        issues.extend(get_libxml2_runtime_issues(root_dir=root_dir))
    elif pkg_name == "shared-mime-info":
        issues.extend(get_shared_mime_info_runtime_issues(root_dir=root_dir))
    elif pkg_name == "util-linux":
        issues.extend(get_util_linux_runtime_issues(root_dir=root_dir))

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
        rootfs_dir = ROOTFS_DIR
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

def overlay_rootfs_entry(source_path, dest_path):
    """Copy a rootfs entry into place, replacing conflicting files or symlinks."""
    if os.path.islink(source_path):
        if os.path.lexists(dest_path):
            remove_path(dest_path)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        os.symlink(os.readlink(source_path), dest_path)
        return 1

    if os.path.isdir(source_path):
        if os.path.lexists(dest_path) and not (os.path.isdir(dest_path) and not os.path.islink(dest_path)):
            remove_path(dest_path)
        os.makedirs(dest_path, exist_ok=True)
        copied_count = 0
        for entry in sorted(os.listdir(source_path)):
            copied_count += overlay_rootfs_entry(
                os.path.join(source_path, entry),
                os.path.join(dest_path, entry),
            )
        return copied_count

    if os.path.lexists(dest_path):
        remove_path(dest_path)
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    shutil.copy2(source_path, dest_path)
    return 1

def normalize_rootfs_multiarch_layout(root_dir=None, report=False):
    """Fold legacy lib64 installs back into the canonical Debian multiarch layout."""
    root_dir = root_dir or ROOTFS_DIR
    migration_specs = [
        (
            os.path.join(root_dir, "lib64"),
            os.path.join(root_dir, "lib", "x86_64-linux-gnu"),
            {"x86_64-linux-gnu"},
        ),
        (
            os.path.join(root_dir, "usr", "lib64"),
            os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu"),
            {"x86_64-linux-gnu"},
        ),
        (
            os.path.join(root_dir, "usr", "lib", "pkgconfig"),
            os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu", "pkgconfig"),
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

    normalize_duplicate_usr_lib_subdir(root_dir=root_dir, report=report)
    prune_shadowed_rootfs_runtime_libraries(root_dir=root_dir, report=report)
    normalize_rootfs_usr_lib_top_level(root_dir=root_dir, report=report)
    normalize_pkgconfig_metadata(root_dir=root_dir, report=report)
    normalize_libtool_archive_metadata(root_dir=root_dir, report=report)
    ensure_multiarch_dev_compat(root_dir=root_dir, report=report)
    return migrated_entries

def normalize_duplicate_usr_lib_subdir(root_dir=None, report=False):
    """Move misinstalled library artifacts from /usr/lib/lib into the multiarch libdir."""
    root_dir = root_dir or ROOTFS_DIR
    duplicate_dir = os.path.join(root_dir, "usr", "lib", "lib")
    canonical_dir = os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu")
    if not os.path.isdir(duplicate_dir):
        return []

    os.makedirs(canonical_dir, exist_ok=True)
    migrated_entries = []
    for entry in sorted(os.listdir(duplicate_dir)):
        source_path = os.path.join(duplicate_dir, entry)
        if os.path.isdir(source_path) and not os.path.islink(source_path):
            continue
        if not (
            entry.startswith("lib")
            and (".so" in entry or entry.endswith(".a") or entry.endswith(".la"))
        ):
            continue
        dest_path = os.path.join(canonical_dir, entry)
        merge_rootfs_entry(source_path, dest_path)
        migrated_entries.append((source_path, dest_path))

    if os.path.isdir(duplicate_dir) and not os.listdir(duplicate_dir):
        os.rmdir(duplicate_dir)

    if report and migrated_entries:
        print_info("[*] Normalizing duplicate /usr/lib/lib library installs...")
        for source_path, dest_path in migrated_entries:
            print_info(f"  Migrated {source_path} -> {dest_path}")

    return migrated_entries

def prune_shadowed_rootfs_runtime_libraries(root_dir=None, report=False):
    """Remove non-core /lib runtime entries when the canonical /usr/lib copy exists."""
    rootfs_dir = root_dir or ROOTFS_DIR
    legacy_dir = os.path.join(rootfs_dir, "lib", "x86_64-linux-gnu")
    canonical_dir = os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu")
    if not (os.path.isdir(legacy_dir) and os.path.isdir(canonical_dir)):
        return []
    try:
        if os.path.samefile(legacy_dir, canonical_dir):
            return []
    except FileNotFoundError:
        return []

    protected_paths = set()
    for artifacts in PACKAGE_MANIFESTS.values():
        for artifact in artifacts:
            if any(ch in artifact for ch in "*?["):
                continue
            rel_artifact = artifact.lstrip("/")
            if rel_artifact.startswith("lib/"):
                protected_paths.add(rel_artifact)

    removed_entries = []
    for entry in sorted(os.listdir(legacy_dir)):
        legacy_path = os.path.join(legacy_dir, entry)
        canonical_path = os.path.join(canonical_dir, entry)
        rel_legacy = os.path.relpath(legacy_path, rootfs_dir).replace(os.sep, "/")

        if not (entry.startswith("lib") or entry.startswith("ld-")):
            continue
        if rel_legacy in protected_paths:
            continue
        if is_core_multiarch_runtime_library(entry):
            continue
        if not os.path.lexists(legacy_path) or not os.path.lexists(canonical_path):
            continue
        if os.path.isdir(legacy_path) and not os.path.islink(legacy_path):
            continue
        if os.path.isdir(canonical_path) and not os.path.islink(canonical_path):
            continue

        remove_path(legacy_path)
        removed_entries.append((legacy_path, canonical_path))

    if removed_entries:
        overlay_paths = load_host_dev_overlay_paths()
        if overlay_paths:
            for legacy_path, _ in removed_entries:
                rel_legacy = os.path.relpath(legacy_path, rootfs_dir).replace(os.sep, "/")
                overlay_paths.discard(rel_legacy)
            save_host_dev_overlay_paths(overlay_paths)

    if report and removed_entries:
        print_info("[*] Pruning shadowed /lib runtime libraries in favor of Debian multiarch...")
        for legacy_path, canonical_path in removed_entries[:20]:
            print_info(f"  Removed {legacy_path}; canonical runtime is {canonical_path}")
        if len(removed_entries) > 20:
            print_info(f"  Removed {len(removed_entries) - 20} additional shadowed /lib runtime libraries.")

    return removed_entries

def normalize_rootfs_usr_lib_top_level(root_dir=None, report=False):
    """Relocate top-level /usr/lib libraries into the canonical multiarch directory."""
    root_dir = root_dir or ROOTFS_DIR
    usr_lib_dir = os.path.join(root_dir, "usr", "lib")
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
        rel_path = os.path.relpath(source_path, root_dir).replace(os.sep, "/")
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
    dirs_to_remove = [
        BOOTSTRAP_ROOTFS_DIR,
        BUILD_SYSROOT_DIR,
        FINAL_ROOTFS_DIR,
        os.path.join(ROOT_DIR, "glibc-build"),
        LOG_DIR,
        OUTPUT_DIR,
        ISO_WORK_DIR,
        os.path.join(ROOT_DIR, "initramfs_build"),
    ]
    seen = set()
    for path in dirs_to_remove:
        if path in seen:
            continue
        seen.add(path)
        if os.path.exists(path):
            print_info(f"[*] Removing {path}...")
            subprocess.run(["rm", "-rf", path], check=False)
    
    # Remove ISOs
    if os.path.lexists(ISO_SYMLINK_PATH):
        os.remove(ISO_SYMLINK_PATH)
    if os.path.isdir(ISO_OUTPUT_DIR):
        for iso_path in glob.glob(os.path.join(ISO_OUTPUT_DIR, "GeminiOS-*.iso")):
            if os.path.exists(iso_path):
                os.remove(iso_path)
    if os.path.exists(HOST_DEV_OVERLAY_FILE):
        os.remove(HOST_DEV_OVERLAY_FILE)
    
    print_success("[!] Clean completed.")

def sync_kernel():
    print_section("\n=== Syncing Kernel Image ===")
    kernel_src, used_fallback_kernel = resolve_kernel_bzimage_path()
    kernel_dest = os.path.join(ROOTFS_DIR, "boot", "kernel")
    
    if os.path.exists(kernel_src):
        if used_fallback_kernel:
            print_warning(
                f" [WARNING] Configured kernel {KERNEL_VERSION} was not found; using "
                f"{kernel_tree_name_from_bzimage(kernel_src)} instead."
            )
        print_info(f"[*] Copying {kernel_src} to {kernel_dest} and zoneinfo...")
        os.makedirs(os.path.dirname(kernel_dest), exist_ok=True)
        subprocess.run(f"cp {kernel_src} {kernel_dest}", shell=True, executable="/usr/bin/bash")
        subprocess.run(f"cp -r /usr/share/zoneinfo {os.path.join(ROOTFS_DIR, 'usr', 'share')}", shell=True, executable="/usr/bin/bash")
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

    build_mode = get_port_build_mode(pkg_name)
    host_env_packages = {"kernel_headers", "glibc", "wayland"}
    use_target_env = build_mode != "host-only-tool" and pkg_name not in host_env_packages
    ret = run_command(build_script, cwd=pkg_dir, log_file=log_file, use_target_env=use_target_env, debug=debug)
    
    duration = time.time() - start_time
    if ret == 0:
        normalize_rootfs_multiarch_layout(root_dir=ROOTFS_DIR, report=debug)
        # Post-build Verification
        verification_issues = get_package_verification_issues(pkg_name, root_dir=ROOTFS_DIR)
        closure_report = os.path.join(LOG_DIR, f"{pkg_name}-runtime-closure.json")
        closure_issues = generate_runtime_closure_report(
            ROOTFS_DIR,
            closure_report,
            candidate_paths=collect_package_artifact_paths(pkg_name, root_dir=ROOTFS_DIR),
        )
        if build_mode != "host-only-tool":
            verification_issues.extend(closure_issues)
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
    """Compatibility helper for migrating old host-dev overlays into the build sysroot."""
    print_section("\n=== Installing C/C++ Development Environment (Compatibility Mode) ===")
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
            os.path.join(ROOTFS_DIR, "usr", "lib", "x86_64-linux-gnu"),
            os.path.join(ROOTFS_DIR, "lib", "x86_64-linux-gnu"),
            os.path.join(ROOTFS_DIR, "usr", "lib", "gcc"),
            os.path.join(ROOTFS_DIR, "usr", "include"),
            os.path.join(ROOTFS_DIR, "usr", "local", "include"),
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
        rootfs_dir = ROOTFS_DIR
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
        os.path.join(ROOTFS_DIR, "usr", "include", "stdio.h"),
        os.path.join(ROOTFS_DIR, "usr", "include", "pthread.h"),
        os.path.join(ROOTFS_DIR, "usr", "include", "x86_64-linux-gnu", "bits", "pthreadtypes.h"),
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
        dest = os.path.join(ROOTFS_DIR, path.lstrip("/"))
        dest = resolve_rootfs_copy_destination(dest)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        print_info(f"  Copying {path} -> {dest}")
        subprocess.run(
            f"cp -a --no-preserve=ownership -n {path}/. {dest}/ 2>/dev/null || true",
            shell=True,
            executable="/usr/bin/bash",
        )
        record_overlay_tree(path, dest)

    # 2. Resolve and Copy Development Libraries (Static and object files only).
    # Runtime shared libraries must remain package-owned so the final image keeps
    # a Debian-like library layout instead of inheriting host ABI state.
    print_info("[*] Copying host static/object development libraries only...")
    
    lib_search_paths = [
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib64",
    ]
    # Do not seed host shared libraries from /lib*. Those paths are reserved for
    # target-owned core runtime pieces (glibc/libxcrypt). Overlaying them causes
    # stale host copies to shadow the canonical /usr/lib runtime during boot.
    
    # Dynamically find GCC lib dir
    gcc_lib_file = subprocess.run("gcc -print-libgcc-file-name", shell=True, capture_output=True, text=True, executable="/usr/bin/bash").stdout.strip()
    if gcc_lib_file:
        lib_search_paths.append(os.path.dirname(gcc_lib_file))
    
    # Target patterns to ensure we have everything needed for development
    target_patterns = [
        "*.a", "*.o"
    ]

    skipped_shared_libs = 0
    for lib_dir in lib_search_paths:
        if not os.path.exists(lib_dir):
            continue
        print_info(f"  Scanning {lib_dir} for libraries...")
        for pattern in target_patterns:
            find_cmd = f"find {lib_dir} -maxdepth 1 -name '{pattern}'"
            found_items = subprocess.run(find_cmd, shell=True, capture_output=True, text=True, executable="/usr/bin/bash").stdout.splitlines()
            for item_path in found_items:
                # Determine where it should go in rootfs
                # We try to preserve the original path structure for development files
                dest = os.path.join(ROOTFS_DIR, item_path.lstrip("/"))
                dest = resolve_rootfs_copy_destination(dest)

                os.makedirs(os.path.dirname(dest), exist_ok=True)
                sanitize_overlay_destination(dest)
                overlay_paths.add(os.path.relpath(dest, ROOTFS_DIR).replace(os.sep, "/"))
                if not os.path.exists(dest):
                    if os.path.islink(item_path):
                         subprocess.run(f"cp -P {item_path} {dest}", shell=True, executable="/usr/bin/bash")
                    else:
                         subprocess.run(
                             f"cp -a --no-preserve=ownership {item_path} {dest}",
                             shell=True,
                             executable="/usr/bin/bash",
                         )

        shared_find_cmd = "find {} -maxdepth 1 -name '*.so*'".format(lib_dir)
        skipped_shared_libs += len(
            subprocess.run(
                shared_find_cmd,
                shell=True,
                capture_output=True,
                text=True,
                executable="/usr/bin/bash",
            ).stdout.splitlines()
        )

    save_host_dev_overlay_paths(overlay_paths)
    if skipped_shared_libs:
        print_info(f"  Skipped {skipped_shared_libs} host shared libraries to keep rootfs runtime package-owned.")
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
        os.path.join(ROOTFS_DIR, "usr", "include"),
        os.path.join(ROOTFS_DIR, "usr", "local", "include"),
    ]
    candidate_paths.extend(
        glob.glob(os.path.join(ROOTFS_DIR, "usr", "lib", "x86_64-linux-gnu", "gcc", "*", "*", "include"))
    )
    candidate_paths.extend(
        glob.glob(os.path.join(ROOTFS_DIR, "usr", "include", "*", "c++", "*"))
    )
    candidate_paths.extend(
        glob.glob(os.path.join(ROOTFS_DIR, "usr", "lib64", "gcc", "*", "*", "include"))
    )

    for candidate in candidate_paths:
        normalize_dev_tree(candidate)

def prepare_rootfs():
    print_section("\n=== Preparing Build Stages ===")
    prepare_stage_dirs()
    if not prepare_build_system_helpers():
        sys.exit(1)
    normalize_rootfs_multiarch_layout(root_dir=ROOTFS_DIR, report=True)
    subprocess.run(f"find {ROOTFS_DIR} -name '*.la' -delete", shell=True, executable="/usr/bin/bash")

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
        "usr/lib/dbus-1.0/dbus-daemon-launch-helper",
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
        path = os.path.join(FINAL_ROOTFS_DIR, f)
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
        path = os.path.join(FINAL_ROOTFS_DIR, rel_path)
        if not os.path.exists(path):
            print_error(f"  [MISSING] {rel_path}")
            return False

    shadowed_runtime_issues = get_shadowed_runtime_library_issues(root_dir=FINAL_ROOTFS_DIR)
    if shadowed_runtime_issues:
        print_error(f"  [FAILED] {shadowed_runtime_issues[0]}")
        print_error("           Remove stale /lib shadow copies so early boot uses the canonical /usr/lib runtime.")
        return False
    print_success("  [OK] Debian multiarch runtime layout")

    runtime_closure_issues = generate_runtime_closure_report(FINAL_ROOTFS_DIR, RUNTIME_CLOSURE_REPORT)
    if runtime_closure_issues:
        print_error(f"  [FAILED] {runtime_closure_issues[0]}")
        print_error(f"           See {RUNTIME_CLOSURE_REPORT} for the full staged ELF closure report.")
        return False
    print_success("  [OK] ELF runtime closure")

    pkgconfig_layout_issues = get_all_pkgconfig_layout_issues(root_dir=FINAL_ROOTFS_DIR)
    if pkgconfig_layout_issues:
        print_error(f"  [FAILED] {pkgconfig_layout_issues[0]}")
        print_error("           Staged pkg-config metadata still leaks lib64 or build-root paths.")
        return False
    print_success("  [OK] pkg-config metadata layout")

    glibc_runtime_issues = get_glibc_runtime_issues(root_dir=FINAL_ROOTFS_DIR)
    if glibc_runtime_issues:
        print_error(f"  [FAILED] {glibc_runtime_issues[0]}")
        print_error("           The final image still contains a mismatched loader/libc runtime pair.")
        return False
    print_success("  [OK] glibc loader/runtime coherence")

    util_linux_runtime_issues = get_util_linux_runtime_issues(root_dir=FINAL_ROOTFS_DIR)
    if util_linux_runtime_issues:
        print_error(f"  [FAILED] {util_linux_runtime_issues[0]}")
        print_error("           Early userspace must be runnable entirely from the staged rootfs.")
        return False
    print_success("  [OK] util-linux runtime closure")

    selinux_runtime_issues = get_selinux_runtime_issues(root_dir=FINAL_ROOTFS_DIR)
    if selinux_runtime_issues:
        print_error(f"  [FAILED] {selinux_runtime_issues[0]}")
        print_error("           The staged SELinux policy/userspace stack is incomplete.")
        return False
    print_success("  [OK] SELinux policy/runtime")

    early_userspace_smoke_tests = [
        ("bin/bash", ["--version"]),
        ("bin/mount", ["--help"]),
        ("bin/umount", ["--help"]),
        ("bin/ls", ["--version"]),
        ("bin/sleep", ["0"]),
        ("sbin/switch_root", ["--help"]),
    ]
    for rel_path, args in early_userspace_smoke_tests:
        ok, detail = run_staged_binary_smoke_test(FINAL_ROOTFS_DIR, rel_path, args)
        if not ok:
            print_error(f"  [FAILED] staged smoke test for {rel_path}: {detail}")
            print_error("           The final rootfs contains an ELF/runtime mismatch that would break early boot.")
            return False
    print_success("  [OK] early userspace smoke tests")

    dbus_runtime_issues = get_dbus_runtime_abi_issues(root_dir=FINAL_ROOTFS_DIR)
    if dbus_runtime_issues:
        print_error(f"  [FAILED] {dbus_runtime_issues[0]}")
        print_error("           A staged package likely overwrote GeminiOS DBus binaries or libraries.")
        return False
    print_success("  [OK] DBus runtime ABI")

    dbus_helper_permission_issues = get_dbus_helper_permission_issues(root_dir=FINAL_ROOTFS_DIR)
    if dbus_helper_permission_issues:
        print_error(f"  [FAILED] {dbus_helper_permission_issues[0]}")
        print_error("           The D-Bus system activation helper must be staged with setuid mode 4754.")
        return False
    print_success("  [OK] DBus helper staging permissions")

    python_runtime_issues = get_python_runtime_issues(root_dir=FINAL_ROOTFS_DIR)
    if python_runtime_issues:
        print_error(f"  [FAILED] {python_runtime_issues[0]}")
        print_error("           The staged Python runtime or wrapper is not usable for Python-based packages.")
        return False
    if os.path.exists(os.path.join(FINAL_ROOTFS_DIR, "usr", "bin", "python3")):
        print_success("  [OK] Python runtime")
    
    print_success("[!] Rootfs integrity check PASSED.")
    return True

def finalize_rootfs():
    print_section("\n=== Finalizing Rootfs (Glue & Fixups) ===")
    assemble_final_rootfs()
    
    # 1. Permissions (su/sudo + dbus helper)
    print_info("[*] Setting SUID permissions...")
    suid_fixups = [
        (os.path.join(FINAL_ROOTFS_DIR, "bin", "apps", "system", "su"), None),
        (os.path.join(FINAL_ROOTFS_DIR, "bin", "apps", "system", "sudo"), None),
        (os.path.join(FINAL_ROOTFS_DIR, DBUS_HELPER_REL_PATH), DBUS_HELPER_REQUIRED_MODE),
    ]
    for path, exact_mode in suid_fixups:
        if not os.path.exists(path):
            continue
        current_mode = stat.S_IMODE(os.lstat(path).st_mode)
        new_mode = exact_mode if exact_mode is not None else (current_mode | stat.S_ISUID)
        if current_mode != new_mode:
            os.chmod(path, new_mode)

    helper_path = os.path.join(FINAL_ROOTFS_DIR, DBUS_HELPER_REL_PATH)
    if os.path.exists(helper_path) and os.geteuid() == 0:
        try:
            os.chown(helper_path, DBUS_HELPER_REQUIRED_UID, DBUS_HELPER_REQUIRED_GID)
        except OSError as exc:
            print_warning(f"  Could not chown {DBUS_HELPER_REL_PATH.replace(os.sep, '/')}: {exc}")

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
        link_path = os.path.join(FINAL_ROOTFS_DIR, link)
        if not os.path.exists(link_path):
            target_path = os.path.join(FINAL_ROOTFS_DIR, target)
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
    # Glib Schemas
    schema_tool = os.path.join(FINAL_ROOTFS_DIR, "usr", "bin", "glib-compile-schemas")
    schema_dir = os.path.join(FINAL_ROOTFS_DIR, "usr", "share", "glib-2.0", "schemas")
    if os.path.exists(schema_tool) and os.path.exists(schema_dir):
        glib_issues = get_package_verification_issues("glib", root_dir=FINAL_ROOTFS_DIR)
        if glib_issues:
            print_warning(
                "  Skipping glib-compile-schemas because the staged GLib runtime is inconsistent: "
                + glib_issues[0]
            )
        else:
            try:
                result = run_staged_binary_command(
                    FINAL_ROOTFS_DIR,
                    "usr/bin/glib-compile-schemas",
                    [schema_dir],
                )
                if result.returncode != 0:
                    schema_error = (result.stderr or result.stdout or f"exit code {result.returncode}").strip().splitlines()
                    detail = schema_error[-1] if schema_error else f"exit code {result.returncode}"
                    print_warning(f"  glib-compile-schemas failed: {detail}")
            except FileNotFoundError as exc:
                print_warning(f"  Could not run glib-compile-schemas: {exc}")

    # Mime Database
    mime_tool = os.path.join(FINAL_ROOTFS_DIR, "usr", "bin", "update-mime-database")
    mime_dir = os.path.join(FINAL_ROOTFS_DIR, "usr", "share", "mime")
    if os.path.exists(mime_tool) and os.path.exists(mime_dir):
        mime_issues = (
            get_package_verification_issues("libxml2", root_dir=FINAL_ROOTFS_DIR)
            + get_package_verification_issues("shared-mime-info", root_dir=FINAL_ROOTFS_DIR)
        )
        if mime_issues:
            print_warning(
                "  Skipping update-mime-database because the staged MIME/libxml runtime is inconsistent: "
                + mime_issues[0]
            )
        else:
            try:
                result = run_staged_binary_command(
                    FINAL_ROOTFS_DIR,
                    "usr/bin/update-mime-database",
                    [mime_dir],
                )
                if result.returncode != 0:
                    mime_error = (result.stderr or result.stdout or f"exit code {result.returncode}").strip().splitlines()
                    detail = mime_error[-1] if mime_error else f"exit code {result.returncode}"
                    print_warning(f"  update-mime-database failed: {detail}")
            except FileNotFoundError as exc:
                print_warning(f"  Could not run update-mime-database: {exc}")

    # 4. Create Live Marker
    # This file tells ginit that we are booting the Live CD (enabling autologin)
    # The installer will remove this file from the installed system.
    with open(os.path.join(FINAL_ROOTFS_DIR, "etc", "geminios-live"), "w") as f:
        f.write("1")

    # 5. Seed gpkg configuration files. Debian testing is built-in; optional
    # GeminiOS-native repositories can be preseeded from build config.
    print_info("[*] Seeding gpkg repository configuration...")
    gpkg_dir = os.path.join(FINAL_ROOTFS_DIR, "etc", "gpkg")
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
    with open(os.path.join(FINAL_ROOTFS_DIR, "etc", "geminios-version"), "w") as f:
        f.write(release["display_version"] + "\n")
    with open(os.path.join(FINAL_ROOTFS_DIR, "etc", "geminios-build-id"), "w") as f:
        f.write(release["build_id"] + "\n")
    
    with open(os.path.join(FINAL_ROOTFS_DIR, "etc", "os-release"), "w") as f:
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
    machine_id_path = os.path.join(FINAL_ROOTFS_DIR, "etc", "machine-id")
    dbus_uuid_path = os.path.join(FINAL_ROOTFS_DIR, "var", "lib", "dbus", "machine-id")
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
    prune_unused_host_runtime_libs(root_dir=FINAL_ROOTFS_DIR)

    # 9. Strip host dev-overlay leftovers before packaging the final image.
    prune_host_dev_overlay_artifacts(root_dir=FINAL_ROOTFS_DIR)

    # 10. Restore multiarch compatibility symlinks for the in-OS toolchain.
    normalize_rootfs_multiarch_layout(root_dir=FINAL_ROOTFS_DIR, report=True)

    # 11. Materialize the Debian SELinux module set into a usable staged
    # policy/file-context store before any relabel or integrity verification.
    materialize_selinux_policy_store(root_dir=FINAL_ROOTFS_DIR)

    # 12. Prepare SELinux policy/config and opportunistically pre-label the
    # staged rootfs when the build host can support it. The live image still
    # stays permissive by default; the installer flips installed systems to
    # enforcing after a successful relabel.
    stage_selinux_rootfs_labels(root_dir=FINAL_ROOTFS_DIR)

    # 13. Final Integrity Check
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

def stage_selinux_rootfs_labels(root_dir=None):
    """Best-effort SELinux relabel for the staged rootfs when the host allows it."""
    rootfs_dir = root_dir or FINAL_ROOTFS_DIR
    config_path = os.path.join(rootfs_dir, "etc", "selinux", "config")
    if not os.path.exists(config_path):
        return

    print_info("[*] Preparing staged SELinux labels...")

    setfiles_rel = find_existing_rootfs_relpath(
        rootfs_dir,
        ["usr/sbin/setfiles", "sbin/setfiles"],
    )
    file_contexts_path = None
    for candidate in (
        os.path.join(rootfs_dir, "etc", "selinux", "default", "contexts", "files", "file_contexts"),
        os.path.join(rootfs_dir, "etc", "selinux", "targeted", "contexts", "files", "file_contexts"),
    ):
        if os.path.exists(candidate):
            file_contexts_path = candidate
            break

    if not setfiles_rel or not file_contexts_path:
        print_warning("  Skipping staged SELinux relabel because setfiles or file_contexts is missing.")
        return

    if os.geteuid() != 0:
        print_warning(
            "  Skipping staged SELinux relabel because the builder is not running as root. "
            "The live image will remain permissive and the installer will relabel installed systems."
        )
        return

    env = os.environ.copy()
    env.setdefault("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
    result = run_staged_binary_command(
        rootfs_dir,
        setfiles_rel,
        ["-F", "-r", rootfs_dir, file_contexts_path, rootfs_dir],
        env=env,
    )
    if result.returncode != 0:
        detail_lines = (result.stderr or result.stdout or f"exit code {result.returncode}").strip().splitlines()
        detail = detail_lines[-1] if detail_lines else f"exit code {result.returncode}"
        print_warning(
            "  Staged SELinux relabel failed; the build will continue in permissive-live mode. "
            f"Detail: {detail}"
        )
        return

    print_success("  ✓ Applied staged SELinux file labels")

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
        match = re.search(r"Requesting program interpreter:\s*([^\]]+)", line)
        if match:
            return match.group(1).strip()
    return None

def get_elf_rpaths(binary_path):
    """Return RPATH/RUNPATH entries declared by an ELF binary."""
    result = subprocess.run(
        ["readelf", "-d", binary_path],
        capture_output=True,
        text=True,
        check=False,
    )
    entries = []
    for line in result.stdout.splitlines():
        if "(RPATH)" not in line and "(RUNPATH)" not in line:
            continue
        start = line.find("[")
        end = line.find("]", start + 1)
        if start != -1 and end != -1:
            entries.extend([entry for entry in line[start + 1:end].split(":") if entry])
    return entries

def is_core_multiarch_runtime_library(lib_filename):
    """Return True for libraries that legitimately live in /lib on Debian-style systems."""
    core_prefixes = (
        "ld-linux",
        "ld-",
        "libBrokenLocale.so",
        "libBrokenLocale-",
        "libanl.so",
        "libanl-",
        "libc.so",
        "libc-",
        "libcrypt.so",
        "libcrypt-",
        "libdl.so",
        "libdl-",
        "libm.so",
        "libm-",
        "libnsl.so",
        "libnsl-",
        "libnss_",
        "libpthread.so",
        "libpthread-",
        "libresolv.so",
        "libresolv-",
        "librt.so",
        "librt-",
        "libthread_db.so",
        "libthread_db-",
        "libutil.so",
        "libutil-",
    )
    return any(lib_filename.startswith(prefix) for prefix in core_prefixes)

def iter_rootfs_library_search_paths(lib_filename):
    """Yield library search paths in the preferred Debian-style order."""
    if is_core_multiarch_runtime_library(lib_filename):
        return [
            "lib/x86_64-linux-gnu",
            "usr/lib/x86_64-linux-gnu",
            "lib64",
            "usr/lib64",
            "lib",
            "usr/lib",
        ]
    return [
        "usr/lib/x86_64-linux-gnu",
        "lib/x86_64-linux-gnu",
        "usr/lib64",
        "lib64",
        "usr/lib",
        "lib",
    ]

def rootfs_abspath(rootfs_dir, path):
    """Return an absolute path interpreted within the staged rootfs namespace."""
    rootfs_dir = os.path.realpath(rootfs_dir)
    if os.path.isabs(path):
        normalized = os.path.normpath(path)
        try:
            if os.path.commonpath([rootfs_dir, normalized]) == rootfs_dir:
                return normalized
        except ValueError:
            pass
        return os.path.normpath(os.path.join(rootfs_dir, path.lstrip("/")))
    return os.path.normpath(os.path.join(rootfs_dir, path))

def resolve_rootfs_path(rootfs_dir, path, max_depth=40):
    """Resolve symlinks using rootfs semantics, keeping absolute targets inside rootfs."""
    rootfs_dir = os.path.realpath(rootfs_dir)
    current = rootfs_abspath(rootfs_dir, path)
    seen = set()

    for _ in range(max_depth):
        if current in seen:
            break
        seen.add(current)
        if not os.path.lexists(current) or not os.path.islink(current):
            break
        target = os.readlink(current)
        if os.path.isabs(target):
            current = os.path.normpath(os.path.join(rootfs_dir, target.lstrip("/")))
        else:
            current = os.path.normpath(os.path.join(os.path.dirname(current), target))

    return current

def expand_rootfs_runtime_search_dirs(rootfs_dir, current_path=None, rpaths=None):
    """Map ELF RPATH/RUNPATH entries into concrete directories inside the staged rootfs."""
    rootfs_dir = os.path.realpath(rootfs_dir)
    current_dir = os.path.dirname(resolve_rootfs_path(rootfs_dir, current_path)) if current_path else None
    resolved_dirs = []
    seen = set()

    def add_dir(path):
        if not path:
            return
        candidate = resolve_rootfs_path(rootfs_dir, path)
        if not os.path.isdir(candidate):
            return
        try:
            if os.path.commonpath([rootfs_dir, candidate]) != rootfs_dir:
                return
        except ValueError:
            return
        if candidate in seen:
            return
        seen.add(candidate)
        resolved_dirs.append(candidate)

    for entry in rpaths or []:
        if not entry:
            continue
        if entry.startswith("$ORIGIN"):
            if not current_dir:
                continue
            suffix = entry[len("$ORIGIN"):].lstrip("/")
            add_dir(current_dir if not suffix else os.path.join(current_dir, suffix))
        elif entry.startswith("/"):
            add_dir(os.path.join(rootfs_dir, entry.lstrip("/")))
        elif current_dir:
            add_dir(os.path.join(current_dir, entry))

    return resolved_dirs

def find_rootfs_library(rootfs_dir, lib_filename, current_path=None, rpaths=None):
    """Find a library within the target rootfs."""
    if current_path:
        sibling_candidate = os.path.join(os.path.dirname(resolve_rootfs_path(rootfs_dir, current_path)), lib_filename)
        if os.path.exists(sibling_candidate):
            return sibling_candidate

    for search_dir in expand_rootfs_runtime_search_dirs(rootfs_dir, current_path=current_path, rpaths=rpaths):
        candidate = os.path.join(search_dir, lib_filename)
        if os.path.exists(candidate):
            return candidate

    for search_path in iter_rootfs_library_search_paths(lib_filename):
        candidate = os.path.join(rootfs_dir, search_path, lib_filename)
        if os.path.exists(candidate):
            return candidate
    return None

def get_shadowed_runtime_library_issues(root_dir=None):
    """Report non-core libraries that still exist in both /lib and /usr/lib."""
    rootfs_dir = root_dir or ROOTFS_DIR
    legacy_dir = os.path.join(rootfs_dir, "lib", "x86_64-linux-gnu")
    canonical_dir = os.path.join(rootfs_dir, "usr", "lib", "x86_64-linux-gnu")
    if not (os.path.isdir(legacy_dir) and os.path.isdir(canonical_dir)):
        return []

    issues = []
    for entry in sorted(os.listdir(legacy_dir)):
        legacy_path = os.path.join(legacy_dir, entry)
        canonical_path = os.path.join(canonical_dir, entry)
        if not (entry.startswith("lib") or entry.startswith("ld-")):
            continue
        if is_core_multiarch_runtime_library(entry):
            continue
        if not (os.path.exists(legacy_path) and os.path.exists(canonical_path)):
            continue
        if os.path.isdir(legacy_path) and not os.path.islink(legacy_path):
            continue
        if os.path.isdir(canonical_path) and not os.path.islink(canonical_path):
            continue
        if os.path.realpath(legacy_path) != os.path.realpath(canonical_path):
            issues.append(
                f"non-core library shadowed in /lib: lib/x86_64-linux-gnu/{entry} overrides usr/lib/x86_64-linux-gnu/{entry}"
            )
    return issues

def generate_runtime_closure_report(root_dir, report_path, candidate_paths=None):
    """Generate a runtime-closure JSON report for staged ELF files."""
    report = {"root_dir": root_dir, "files": []}
    issues = []
    allowed_rpath_prefixes = ("/lib", "/usr/lib", "$ORIGIN")
    allowed_interpreter_prefixes = ("/lib", "/lib64", "/usr/lib", "/usr/lib64")

    if candidate_paths is None:
        paths_to_scan = sorted(iter_rootfs_elf_files(root_dir))
    else:
        paths_to_scan = sorted(
            path for path in {resolve_rootfs_path(root_dir, path) for path in candidate_paths}
            if os.path.isfile(path)
        )

    for path in paths_to_scan:
        rel_path = os.path.relpath(path, root_dir).replace(os.sep, "/")
        interpreter = get_elf_interpreter(path)
        needed = get_elf_needed(path)
        rpaths = get_elf_rpaths(path)
        resolved = {}
        unresolved = []
        interpreter_resolved = None

        for lib_name in needed:
            candidate = find_rootfs_library(root_dir, lib_name, current_path=path, rpaths=rpaths)
            if candidate:
                real_candidate = resolve_rootfs_path(root_dir, candidate)
                try:
                    if os.path.commonpath([root_dir, real_candidate]) != root_dir:
                        issues.append(f"{rel_path} resolves {lib_name} outside the staged rootfs: {real_candidate}")
                        continue
                except ValueError:
                    issues.append(f"{rel_path} resolves {lib_name} outside the staged rootfs: {real_candidate}")
                    continue
                resolved[lib_name] = os.path.relpath(real_candidate, root_dir).replace(os.sep, "/")
            else:
                unresolved.append(lib_name)
                issues.append(f"{rel_path} is missing runtime dependency {lib_name}")

        if interpreter:
            if not interpreter.startswith(allowed_interpreter_prefixes):
                issues.append(f"{rel_path} declares an unexpected interpreter path: {interpreter}")
            interpreter_name = os.path.basename(interpreter)
            interpreter_path = find_rootfs_library(root_dir, interpreter_name, current_path=path, rpaths=rpaths)
            if not interpreter_path:
                issues.append(f"{rel_path} requests interpreter {interpreter} but it is missing from the staged rootfs")
            else:
                real_interpreter = resolve_rootfs_path(root_dir, interpreter_path)
                try:
                    if os.path.commonpath([root_dir, real_interpreter]) != root_dir:
                        issues.append(f"{rel_path} resolves interpreter {interpreter} outside the staged rootfs: {real_interpreter}")
                    else:
                        interpreter_resolved = os.path.relpath(real_interpreter, root_dir).replace(os.sep, "/")
                except ValueError:
                    issues.append(f"{rel_path} resolves interpreter {interpreter} outside the staged rootfs: {real_interpreter}")

        for entry in rpaths:
            if entry.startswith(ROOT_DIR):
                issues.append(f"{rel_path} contains host path in RPATH/RUNPATH: {entry}")
            elif entry.startswith("/") and not entry.startswith(allowed_rpath_prefixes):
                issues.append(f"{rel_path} contains non-target absolute RPATH/RUNPATH entry: {entry}")

        report["files"].append(
            {
                "path": rel_path,
                "interpreter": interpreter,
                "interpreter_resolved": interpreter_resolved,
                "needed": needed,
                "resolved": resolved,
                "unresolved": unresolved,
                "rpath_runpath": rpaths,
            }
        )

    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    # Preserve ordering but de-duplicate messages.
    unique_issues = []
    seen = set()
    for issue in issues:
        if issue in seen:
            continue
        seen.add(issue)
        unique_issues.append(issue)
    return unique_issues

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
                resolved_path = resolve_rootfs_path(rootfs_dir, path)
                if resolved_path in seen or not os.path.isfile(resolved_path):
                    continue
                seen.add(resolved_path)
                yield resolved_path

def collect_rootfs_needed_libs(rootfs_dir, excluded_paths=None):
    """Collect DT_NEEDED library names used by runtime ELF files."""
    excluded_paths = set(excluded_paths or [])
    needed = set()

    for path in iter_rootfs_elf_files(rootfs_dir):
        if path in excluded_paths:
            continue
        needed.update(get_elf_needed(path))

    return needed

def prune_unused_host_runtime_libs(root_dir=None):
    """Remove known host-overlay runtime libraries when nothing in rootfs needs them."""
    print_info("[*] Pruning unused host-overlay runtime libraries...")

    rootfs_dir = root_dir or ROOTFS_DIR
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

def prune_host_dev_overlay_artifacts(root_dir=None):
    """Remove host-overlay files that are not owned by built packages or needed at runtime."""
    print_info("[*] Pruning host development overlay artifacts...")

    overlay_paths = load_host_dev_overlay_paths()
    if not overlay_paths:
        print_success("  ✓ No host development overlay record found.")
        return

    rootfs_dir = root_dir or ROOTFS_DIR
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
    library_prefixes = (
        "usr/lib/x86_64-linux-gnu/",
        "lib/x86_64-linux-gnu/",
        "usr/lib/",
        "lib/",
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
        if rel_path.startswith(library_prefixes):
            preferred_candidate = find_rootfs_library(rootfs_dir, basename)
            if preferred_candidate and os.path.realpath(preferred_candidate) != os.path.realpath(abs_path):
                remove_path(abs_path)
                removed_count += 1
                continue

        if basename in needed_libs:
            kept_count += 1
            continue

        if os.path.isfile(abs_path) and not os.path.islink(abs_path):
            soname = soname_cache.get(abs_path)
            if soname is None:
                soname = get_elf_soname(abs_path)
                soname_cache[abs_path] = soname
            if soname:
                preferred_candidate = find_rootfs_library(rootfs_dir, soname)
                if preferred_candidate and os.path.realpath(preferred_candidate) != os.path.realpath(abs_path):
                    remove_path(abs_path)
                    removed_count += 1
                    continue
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

        if rel_path.startswith(library_prefixes):
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

def ensure_multiarch_dev_compat(root_dir=None, report=True):
    """Collapse lib64 trees into Debian-style multiarch with compatibility symlinks."""
    if report:
        print_info("[*] Restoring multiarch compatibility trees...")
    root_dir = root_dir or ROOTFS_DIR

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
            os.path.join(root_dir, "lib", "x86_64-linux-gnu"),
            os.path.join(root_dir, "lib64"),
            "lib/x86_64-linux-gnu",
        ),
        (
            os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu"),
            os.path.join(root_dir, "usr", "lib64"),
            "lib/x86_64-linux-gnu",
        ),
        (
            os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu", "pkgconfig"),
            os.path.join(root_dir, "usr", "lib", "pkgconfig"),
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
    binary_path = resolve_rootfs_path(rootfs_dir, binary_path)
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
        current_rpaths = get_elf_rpaths(current)

        for lib_filename in get_elf_needed(current):
            candidate = find_rootfs_library(rootfs_dir, lib_filename, current_path=current, rpaths=current_rpaths)
            if not candidate:
                print_warning(f"WARNING: Could not find library {lib_filename} in rootfs for {binary_path}")
                continue

            real_lib = resolve_rootfs_path(rootfs_dir, candidate)
            real_basename = os.path.basename(real_lib)
            dest_real = os.path.join(dest_lib_dir, real_basename)
            if real_basename not in copied:
                shutil.copy2(real_lib, dest_real)
                copied.add(real_basename)
                to_process.append(real_lib)

            candidate_basename = os.path.basename(candidate)
            if candidate_basename != real_basename:
                link_name = os.path.join(dest_lib_dir, lib_filename)
                if os.path.lexists(link_name):
                    os.remove(link_name)
                os.symlink(real_basename, link_name)

    if not os.path.exists(os.path.join(dest_lib_dir, interpreter_name)):
        src_interp = find_rootfs_library(rootfs_dir, interpreter_name)
        if src_interp:
            shutil.copy2(resolve_rootfs_path(rootfs_dir, src_interp), os.path.join(dest_lib_dir, interpreter_name))

    return True

def run_staged_binary_command(root_dir, binary_relpath, args, capture_output=True, text=True, env=None):
    """Run a staged ELF binary with the staged loader/library paths."""
    binary_path = rootfs_abspath(root_dir, binary_relpath)
    resolved_binary_path = resolve_rootfs_path(root_dir, binary_path)
    if not os.path.exists(resolved_binary_path):
        raise FileNotFoundError(f"missing binary: {binary_relpath}")

    interp_path = get_elf_interpreter(resolved_binary_path)
    if interp_path:
        loader_name = os.path.basename(interp_path)
        loader_path = find_rootfs_library(root_dir, loader_name)
        if not loader_path:
            raise FileNotFoundError(f"missing interpreter: {interp_path}")
        runtime_search_dirs = expand_rootfs_runtime_search_dirs(
            root_dir,
            current_path=resolved_binary_path,
            rpaths=get_elf_rpaths(resolved_binary_path),
        )
        runtime_search_dirs.extend(
            [
                os.path.join(root_dir, "lib", "x86_64-linux-gnu"),
                os.path.join(root_dir, "usr", "lib", "x86_64-linux-gnu"),
                os.path.join(root_dir, "lib64"),
                os.path.join(root_dir, "usr", "lib64"),
            ]
        )
        deduped_runtime_search_dirs = []
        seen_dirs = set()
        for path in runtime_search_dirs:
            normalized = os.path.realpath(path)
            if normalized in seen_dirs or not os.path.isdir(normalized):
                continue
            seen_dirs.add(normalized)
            deduped_runtime_search_dirs.append(normalized)
        cmd = [
            loader_path,
            "--library-path",
            ":".join(deduped_runtime_search_dirs),
            resolved_binary_path,
        ]
    else:
        cmd = [resolved_binary_path]

    return subprocess.run(
        cmd + list(args),
        capture_output=capture_output,
        text=text,
        check=False,
        env=env,
    )

def run_staged_binary_smoke_test(root_dir, binary_relpath, args):
    """Run a staged ELF binary with the staged loader/library paths."""
    try:
        result = run_staged_binary_command(root_dir, binary_relpath, args)
    except FileNotFoundError as exc:
        return False, str(exc)

    if result.returncode == 0:
        stderr_text = result.stderr or ""
        if "no version information available" in stderr_text:
            detail = stderr_text.strip().splitlines()
            return False, detail[-1] if detail else "runtime emitted symbol-version warning"
        return True, ""

    stderr = (result.stderr or "").strip().splitlines()
    stdout = (result.stdout or "").strip().splitlines()
    detail = stderr[-1] if stderr else (stdout[-1] if stdout else f"exit code {result.returncode}")
    return False, detail

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

        rootfs = FINAL_ROOTFS_DIR

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
            real_src = resolve_rootfs_path(rootfs, src_path)

            # Determine destination filename (preserve the name requested, e.g. sh)
            dest_file = os.path.join(dest_path, os.path.basename(src_rel))

            # Copy the actual content
            shutil.copy2(real_src, dest_file)
            os.chmod(dest_file, 0o755)

            # Copy dependencies into the initramfs root so the canonical loader/lib dirs exist there.
            copy_with_libs(real_src, work_dir, rootfs, copy_bin=False)

        smoke_args = {
            "bash": ["--version"],
            "sh": ["-c", "exit 0"],
            "mount": ["--help"],
            "ls": ["--version"],
            "mkdir": ["--help"],
            "cat": ["--help"],
            "sleep": ["0"],
            "umount": ["--help"],
            "switch_root": ["--help"],
        }

        print_info("[*] Verifying staged initramfs userland...")
        for src_rel, dest_rel in binaries:
            binary_name = os.path.basename(src_rel)
            binary_path = os.path.join(work_dir, dest_rel, binary_name)
            if not os.path.exists(binary_path):
                continue

            ok, detail = run_staged_binary_smoke_test(
                work_dir,
                os.path.join(dest_rel, binary_name),
                smoke_args.get(binary_name, ["--help"]),
            )
            if not ok:
                print_error(f"FATAL: Initramfs binary self-test failed for {binary_name}: {detail}")
                return False

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
        os.makedirs(os.path.join(ISO_WORK_DIR, "boot"), exist_ok=True)
        initramfs_out = os.path.join(ISO_WORK_DIR, "boot", "initramfs.cpio.lz4")

        pack_cmd = (
            f"cd {shlex.quote(work_dir)} && "
            f"find . -print0 | cpio --null -o --format=newc | lz4 -l -T0 > {shlex.quote(initramfs_out)}"
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
    os.makedirs(os.path.join(ISO_WORK_DIR, "boot", "grub"), exist_ok=True)
        
    # 1. Create SquashFS of Rootfs
    print_info("[*] Creating root.sfs (SquashFS)...")
    sfs_path = os.path.join(ISO_WORK_DIR, "root.sfs")
    if os.path.exists(sfs_path):
        os.remove(sfs_path)
        
    # Using zstd with level 1 for maximum speed/compression balance during development
    # Disabling xattrs also gives a bit of speedup
    squashfs_metadata_args = build_mksquashfs_metadata_args(root_dir=FINAL_ROOTFS_DIR)
    mksquashfs_cmd = (
        f"mksquashfs {shlex.quote(FINAL_ROOTFS_DIR)} {shlex.quote(sfs_path)} "
        f"-comp zstd -Xcompression-level 1 -noappend -wildcards -all-root"
        f"{squashfs_metadata_args} -e staging"
    )
    if run_command(mksquashfs_cmd) != 0:
        print_error(" [FAILED] (mksquashfs)")
        return False

    squashfs_metadata_issues = get_squashfs_metadata_issues(sfs_path, root_dir=FINAL_ROOTFS_DIR)
    if squashfs_metadata_issues:
        print_error(f" [FAILED] (root.sfs metadata: {squashfs_metadata_issues[0]})")
        return False
        
    # 2. Build Minimal Initramfs
    if not create_minimal_initramfs():
        return False

    # 3. Prepare Kernel
    print_info("[*] Preparing kernel...")
    kernel_src = os.path.join(FINAL_ROOTFS_DIR, "boot", "kernel")
    kernel_dest = os.path.join(ISO_WORK_DIR, "boot", "kernel")
    if not os.path.exists(kernel_src):
        # Fallback to source
        kernel_src, used_fallback_kernel = resolve_kernel_bzimage_path()
        if used_fallback_kernel:
            print_warning(
                f" [WARNING] Configured kernel {KERNEL_VERSION} was not found; using "
                f"{kernel_tree_name_from_bzimage(kernel_src)} instead."
            )
    
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
    linux /boot/kernel console=tty0 console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200 net.ifnames=0 selinux=0
    initrd /boot/initramfs.cpio.lz4
}
"""
    with open(os.path.join(ISO_WORK_DIR, "boot", "grub", "grub.cfg"), "w") as f:
        f.write(grub_conf)

    # 5. Build ISO
    release = get_geminios_release_info()
    iso_name = release["iso_name"]
    os.makedirs(ISO_OUTPUT_DIR, exist_ok=True)
    iso_path = os.path.join(ISO_OUTPUT_DIR, iso_name)
    print_info(f"[*] Building {iso_path}...")
    iso_cmd = f"grub-mkrescue -o {shlex.quote(iso_path)} {shlex.quote(ISO_WORK_DIR)}"
    if run_command(iso_cmd) != 0:
        print_error(" [FAILED] (grub-mkrescue)")
        return False

    # Create symlink for convenience
    if os.path.lexists(ISO_SYMLINK_PATH):
        os.remove(ISO_SYMLINK_PATH)
    os.symlink(iso_path, ISO_SYMLINK_PATH)

    print_success(f"[!] ISO built successfully: {iso_path}")
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

    port_audit_issues, port_audit_warnings = audit_requested_port_scripts(packages_to_build)
    if port_audit_warnings:
        print_section("\n=== Port Script Audit ===")
        for warning in port_audit_warnings:
            print_warning(f"WARNING: {warning}")
    if port_audit_issues:
        print_section("\n=== Port Script Audit ===")
        for issue in port_audit_issues:
            print_error(f"ERROR: {issue}")
        sys.exit(1)

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

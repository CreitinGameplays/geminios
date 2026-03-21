#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import json
import shutil
import glob
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
VERSION_FILE = os.path.join(ROOT_DIR, "VERSION")
BUILD_SYSTEM_DIR = os.path.join(ROOT_DIR, "build_system")
PORTS_DIR = os.path.join(ROOT_DIR, "ports")
LOG_DIR = os.path.join(ROOT_DIR, "logs")
ENV_CONFIG = os.path.join(BUILD_SYSTEM_DIR, "env_config.sh")
MANIFEST_FILE = os.path.join(BUILD_SYSTEM_DIR, "package_manifests.json")
DEFAULT_GPKG_REPO = os.environ.get("GPKG_DEFAULT_REPO", "https://repo.creitingameplays.com").rstrip("/")
GPKG_SYSTEM_PROVIDES_FILE = os.environ.get(
    "GPKG_SYSTEM_PROVIDES_FILE",
    os.path.join(BUILD_SYSTEM_DIR, "gpkg_system_provides.txt"),
)

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
    # X Server & Drivers
    "xorg-server",
    "xf86-video-fbdev",
    "libevdev",
    "mtdev",
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
    "libxkbcommon": [
        "wayland",
        "xkeyboard-config",
        "libxcb",
        "xcb-util-keysyms",
        "pkg-config",
        "meson",
        "ninja",
    ],
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

def get_geminios_version():
    """Generates auto-version according to README"""
    base_version = "0.0.1-alpha"
    if os.path.exists(VERSION_FILE):
        with open(VERSION_FILE, "r") as f:
            base_version = f.read().strip()
    
    # date-and-time in mm/dd/yyyy and h:m 24h-format, must convert to UTC+0 time!!!
    # example: 0.0.1-alpha-01252026-1307
    now = datetime.now(timezone.utc)
    date_str = now.strftime("%m%d%Y")
    time_str = now.strftime("%H%M")
    
    return f"{base_version}-{date_str}-{time_str}"

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
    
    # Check against Manifest (Strong Verification)
    if pkg_name in PACKAGE_MANIFESTS:
        artifacts = PACKAGE_MANIFESTS[pkg_name]
        missing_artifacts = []
        for artifact in artifacts:
            # Handle absolute paths vs relative paths
            if artifact.startswith("/"):
                 # Paths starting with / are assumed to be relative to rootfs
                 check_path = os.path.join(ROOT_DIR, "rootfs", artifact.lstrip("/"))
            else:
                 # Try rootfs first, then project root
                 check_path = os.path.join(ROOT_DIR, "rootfs", artifact)
                 if not os.path.exists(check_path):
                     check_path = os.path.join(ROOT_DIR, artifact)

            if not os.path.exists(check_path):
                missing_artifacts.append(artifact)
        
        if not missing_artifacts:
            return True
        else:
            # If manifest exists but files are missing, it's definitely NOT built correctly.
            return False

    return False

def clean_system():
    print_section("=== Cleaning GeminiOS Build Environment ===")
    dirs_to_remove = ["rootfs", "glibc-build", "logs", "isodir", "initramfs_build"]
    for d in dirs_to_remove:
        path = os.path.join(ROOT_DIR, d)
        if os.path.exists(path):
            print_info(f"[*] Removing {d}...")
            subprocess.run(f"rm -rf {path}", shell=True, executable="/usr/bin/bash")
    
    # Remove ISOs
    if os.path.exists("GeminiOS.iso"):
        os.remove("GeminiOS.iso")
    
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
        # Post-build Verification
        if is_built(pkg_name):
            print(color(f" [DONE]", Colors.GREEN + Colors.BOLD) + f" ({duration:.2f}s)")
            return True
        else:
            print(color(f" [FAILED VERIFICATION]", Colors.RED + Colors.BOLD) + " (Artifacts missing)")
            if pkg_name in PACKAGE_MANIFESTS:
                 print_error("    Missing files from manifest:")
                 artifacts = PACKAGE_MANIFESTS[pkg_name]
                 for artifact in artifacts:
                     check_path = os.path.join(ROOT_DIR, "rootfs", artifact)
                     if not os.path.exists(check_path):
                         print_error(f"     - {artifact}")
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

def copy_dev_environment():
    """Copies host C/C++ development environment (headers and libraries) to rootfs"""
    print_section("\n=== Installing C/C++ Development Environment ===")
    
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
                if "/include/c++/" in path or "/lib/gcc/" in path or path == "/usr/local/include":
                    include_paths.append(path)

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
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        print_info(f"  Copying {path} -> {dest}")
        subprocess.run(
            f"cp -a --no-preserve=ownership -n {path}/. {dest}/ 2>/dev/null || true",
            shell=True,
            executable="/usr/bin/bash",
        )

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
                
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if not os.path.exists(dest):
                    if os.path.islink(item_path):
                         subprocess.run(f"cp -P {item_path} {dest}", shell=True, executable="/usr/bin/bash")
                    else:
                         subprocess.run(
                             f"cp -a --no-preserve=ownership {item_path} {dest}",
                             shell=True,
                             executable="/usr/bin/bash",
                         )
                
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
        glob.glob(os.path.join(ROOT_DIR, "rootfs", "usr", "lib64", "gcc", "*", "*", "include"))
    )

    for candidate in candidate_paths:
        normalize_dev_tree(candidate)

def prepare_rootfs():
    print_section("\n=== Preparing Rootfs Structure ===")
    dirs = [
        "bin", "boot", "proc", "sys", "dev", "etc", "tmp", "mnt", "run", "sbin", "lib64",
        "var/repo", "var/log", "var/tmp",
        "usr/bin", "usr/share", "usr/local", "usr/lib64", "usr/include",
        "bin/apps/system"
    ]
    for d in dirs:
        os.makedirs(os.path.join(ROOT_DIR, "rootfs", d), exist_ok=True)

    normalize_dev_environment()

    # Install Dev Environment
    copy_dev_environment()

    # Standardize library paths
    # /lib -> lib64 and /usr/lib -> lib64
    lib_links = [
        ("rootfs/lib", "lib64"),
        ("rootfs/usr/lib", "lib64")
    ]
    for link_path, target in lib_links:
        full_link_path = os.path.join(ROOT_DIR, link_path)
        if not os.path.islink(full_link_path):
            if os.path.isdir(full_link_path):
                # Move contents if directory exists
                for item in os.listdir(full_link_path):
                    s = os.path.join(full_link_path, item)
                    d = os.path.join(ROOT_DIR, "rootfs", "lib64", item)
                    subprocess.run(
                        f"cp -a --no-preserve=ownership -n {s} {d}",
                        shell=True,
                        executable="/usr/bin/bash",
                    )
                subprocess.run(f"rm -rf {full_link_path}", shell=True, executable="/usr/bin/bash")
            os.symlink(target, full_link_path)
            print_info(f"[*] Linked {link_path} to {target}")

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
        "lib64/libcrypt.so.1",
        "usr/lib64/libstdc++.so.6",
        "usr/lib64/libgcc_s.so.1",
        "usr/bin/python3",
        "usr/lib64/libglib-2.0.so",
        "usr/lib64/libgtk-3.so",
        "usr/share/mime/magic",
        "bin/apps/system/gpkg-worker",
        "usr/share/glib-2.0/schemas/gschemas.compiled",
        "usr/share/fonts/TTF/Inter-Regular.otf",
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
        "usr/lib64/libpam.so.0",
        "usr/lib64/libpam_misc.so.0",
        "usr/lib64/libelogind.so.0",
        "usr/lib64/libsystemd.so.0",
    ]
    for rel_path in required_runtime_libs:
        path = os.path.join(ROOT_DIR, "rootfs", rel_path)
        if not os.path.exists(path):
            print_error(f"  [MISSING] {rel_path}")
            return False

    # Verify Python functionality
    print_info("[*] Verifying Python runtime...")
    env = os.environ.copy()
    env["PYTHONHOME"] = os.path.join(ROOT_DIR, "rootfs/usr")
    env["LD_LIBRARY_PATH"] = f"{os.path.join(ROOT_DIR, 'rootfs/usr/lib64')}:{os.path.join(ROOT_DIR, 'rootfs/usr/lib')}"
    
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
    env["LD_LIBRARY_PATH"] = os.path.join(ROOT_DIR, "rootfs/usr/lib64")
    
    # Glib Schemas
    schema_tool = os.path.join(ROOT_DIR, "rootfs/usr/bin/glib-compile-schemas")
    schema_dir = os.path.join(ROOT_DIR, "rootfs/usr/share/glib-2.0/schemas")
    if os.path.exists(schema_tool) and os.path.exists(schema_dir):
        subprocess.run([schema_tool, schema_dir], env=env)

    # Mime Database
    mime_tool = os.path.join(ROOT_DIR, "rootfs/usr/bin/update-mime-database")
    mime_dir = os.path.join(ROOT_DIR, "rootfs/usr/share/mime")
    if os.path.exists(mime_tool) and os.path.exists(mime_dir):
        subprocess.run([mime_tool, mime_dir], env=env)

    # 4. Create Live Marker
    # This file tells ginit that we are booting the Live CD (enabling autologin)
    # The installer will remove this file from the installed system.
    with open(os.path.join(ROOT_DIR, "rootfs/etc/geminios-live"), "w") as f:
        f.write("1")

    # 5. Seed default gpkg repositories from the image build, not from gpkg itself.
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

    repo_list_name = f"repo_{int(time.time())}.list"
    repo_list_path = os.path.join(gpkg_sources_dir, repo_list_name)
    with open(repo_list_path, "w") as f:
        f.write(DEFAULT_GPKG_REPO + "\n")
    print_success(f"  ✓ Added default gpkg repo: {DEFAULT_GPKG_REPO}")

    system_provides_dest = os.path.join(gpkg_dir, "system-provides.list")
    if os.path.exists(GPKG_SYSTEM_PROVIDES_FILE):
        shutil.copy2(GPKG_SYSTEM_PROVIDES_FILE, system_provides_dest)
        print_success(f"  ✓ Added gpkg system provides: {system_provides_dest}")
    else:
        with open(system_provides_dest, "w") as f:
            f.write("")

    # 6. Versioning
    version = get_geminios_version()
    print_info(f"[*] Setting system version: {version}")
    with open(os.path.join(ROOT_DIR, "rootfs/etc/geminios-version"), "w") as f:
        f.write(version + "\n")
    
    with open(os.path.join(ROOT_DIR, "rootfs/etc/os-release"), "w") as f:
        f.write(f'NAME="GeminiOS"\n')
        f.write(f'VERSION="{version}"\n')
        f.write(f'ID=geminios\n')
        f.write(f'PRETTY_NAME="GeminiOS {version}"\n')
        f.write(f'VERSION_ID="{version}"\n')

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

    # 9. Restore multiarch compatibility symlinks for the in-OS toolchain.
    ensure_multiarch_dev_compat()

    # 10. Final Integrity Check
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
    for search_path in ["lib64", "usr/lib64", "lib", "usr/lib"]:
        candidate = os.path.join(rootfs_dir, search_path, lib_filename)
        if os.path.exists(candidate):
            return candidate
    return None

def iter_rootfs_elf_files(rootfs_dir):
    """Yield likely ELF-bearing files from runtime-relevant rootfs paths."""
    candidate_dirs = [
        "bin",
        "sbin",
        "lib64",
        "usr/bin",
        "usr/sbin",
        "usr/lib64",
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
        os.path.join(rootfs_dir, "lib64", "x86_64-linux-gnu"),
        os.path.join(rootfs_dir, "usr", "lib64", "x86_64-linux-gnu"),
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

            if soname in needed_libs:
                print_info(f"  Keeping {family['label']} libraries; still required by rootfs.")
                continue

            for path in paths:
                if os.path.lexists(path):
                    os.remove(path)
                    removed_count += 1
            print_success(f"  ✓ Removed unused {family['label']} library family.")

    soname_groups = {}
    soname_cache = {}
    for base_dir in host_multiarch_dirs:
        if not os.path.isdir(base_dir):
            continue
        for entry in os.listdir(base_dir):
            if not entry.startswith("lib") or ".so" not in entry:
                continue
            path = os.path.join(base_dir, entry)
            real_path = os.path.realpath(path)
            soname = soname_cache.get(real_path)
            if soname is None:
                soname = get_elf_soname(real_path)
                soname_cache[real_path] = soname
            if not soname:
                continue
            soname_groups.setdefault(soname, set()).add(path)

    duplicate_removed = 0
    for soname, paths in sorted(soname_groups.items()):
        runtime_copy = find_rootfs_library(rootfs_dir, soname)
        if runtime_copy or soname not in needed_libs:
            for path in sorted(paths):
                if os.path.lexists(path):
                    os.remove(path)
                    duplicate_removed += 1

    if duplicate_removed:
        print_success(f"  ✓ Removed {duplicate_removed} duplicate host multiarch shared libraries.")

    if not excluded_paths:
        print_success("  ✓ No host multiarch runtime overlay found.")
        return

    if removed_count == 0 and duplicate_removed == 0:
        print_success("  ✓ No unused host-overlay runtime libraries needed pruning.")

def ensure_multiarch_dev_compat():
    """Recreate lightweight multiarch symlinks expected by GCC/ld inside the OS."""
    print_info("[*] Restoring multiarch toolchain compatibility links...")

    link_specs = [
        (os.path.join(ROOT_DIR, "rootfs", "lib64"), os.path.join(ROOT_DIR, "rootfs", "lib64", "x86_64-linux-gnu")),
        (os.path.join(ROOT_DIR, "rootfs", "usr", "lib64"), os.path.join(ROOT_DIR, "rootfs", "usr", "lib64", "x86_64-linux-gnu")),
    ]

    linked_count = 0
    for source_dir, compat_dir in link_specs:
        if not os.path.isdir(source_dir):
            continue
        os.makedirs(compat_dir, exist_ok=True)

        for entry in os.listdir(source_dir):
            if not (entry.startswith("lib") or entry.startswith("ld-linux-")):
                continue
            if ".so" not in entry:
                continue

            source_path = os.path.join(source_dir, entry)
            compat_path = os.path.join(compat_dir, entry)
            if not os.path.exists(source_path) or os.path.lexists(compat_path):
                continue

            rel_target = os.path.relpath(source_path, compat_dir)
            os.symlink(rel_target, compat_path)
            linked_count += 1

    if linked_count:
        print_success(f"  ✓ Restored {linked_count} multiarch compatibility symlinks.")
    else:
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

            # Copy dependencies - ALWAYS copy to work_dir root so libs land in /lib64 or /usr/lib64
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
    version = get_geminios_version()
    iso_name = f"GeminiOS-{version}.iso"
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
        print("  --force     Force rebuild of specified packages (ignoring verification)")
        print("  --debug     Enable verbose debug logging")
        print("  --help      Show this help message")
        print("\nExamples:")
        print(f"  {sys.argv[0]}                   # Build all packages")
        print(f"  {sys.argv[0]} --clean           # Clean everything")
        print(f"  {sys.argv[0]} bash coreutils    # Build specific packages")
        print(f"  {sys.argv[0]} bash --force      # Force rebuild bash")
        sys.exit(0)

    if "--clean" in sys.argv:
        clean_system()
        sys.exit(0)

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

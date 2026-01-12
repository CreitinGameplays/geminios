#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import json
import shutil

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
    "libffi",
    "ncurses",
    "expat",
    "zstd",
    "pkg-config",
    "bison",
    "flex",
    "python",
    "setuptools",
    "markupsafe",
    "mako",
    "meson",
    "ninja",
    "gperf",
    "gettext",
    "perl",
    "texinfo",
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
    # GeminiOS Specifics
    "geminios_core", # init, signals, user_mgmt
    "geminios_pkgs", # ls, pwd, cat, etc.
    "geminios_complex" # gpkg, ping, installer, etc.
]

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
    
    # Remove ISO
    if os.path.exists("GeminiOS.iso"):
        os.remove("GeminiOS.iso")
    
    print_success("[!] Clean completed.")

def sync_kernel():
    print_section("\n=== Syncing Kernel Image ===")
    kernel_src = os.path.join(ROOT_DIR, "external_dependencies/linux-6.6.14/arch/x86/boot/bzImage")
    kernel_dest = os.path.join(ROOT_DIR, "rootfs/boot/kernel")
    
    if os.path.exists(kernel_src):
        print_info(f"[*] Copying {kernel_src} to {kernel_dest}")
        os.makedirs(os.path.dirname(kernel_dest), exist_ok=True)
        subprocess.run(f"cp {kernel_src} {kernel_dest}", shell=True, executable="/usr/bin/bash")
        return True
    else:
        print_warning(f" [WARNING] Kernel image not found at {kernel_src}")
        print_warning("    Ensure you have compiled the kernel manually as described in README.md")
        return False

def build_package(pkg_name, index, total, force=False, debug=False):
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

    # Use target environment for everything after glibc and kernel_headers
    use_target_env = pkg_name not in ["kernel_headers", "glibc"]
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

def prepare_rootfs():
    print_section("\n=== Preparing Rootfs Structure ===")
    dirs = [
        "bin", "boot", "proc", "sys", "dev", "etc", "tmp", "mnt", "run", "sbin", "lib64",
        "var/repo", "var/log", "var/tmp",
        "usr/bin", "usr/share", "usr/local", "usr/lib64",
        "bin/apps/system"
    ]
    for d in dirs:
        os.makedirs(os.path.join(ROOT_DIR, "rootfs", d), exist_ok=True)

    # Copy Host libstdc++ and libgcc
    print_info("[*] Copying host libstdc++ and libgcc...")
    host_lib_paths = [
        "/usr/lib/x86_64-linux-gnu/libstdc++.so.6",
        "/usr/lib/x86_64-linux-gnu/libgcc_s.so.1",
        "/usr/lib64/libstdc++.so.6",
        "/usr/lib64/libgcc_s.so.1",
        "/lib64/libstdc++.so.6",
        "/lib64/libgcc_s.so.1"
    ]
    
    found_libs = {"libstdc++.so.6": False, "libgcc_s.so.1": False}
    for lib_path in host_lib_paths:
        lib_name = os.path.basename(lib_path)
        if os.path.exists(lib_path) and not found_libs[lib_name]:
            dest = os.path.join(ROOT_DIR, "rootfs/usr/lib64", lib_name)
            shutil.copy2(lib_path, dest)
            print_success(f"  ✓ Copied {lib_path} to {dest}")
            found_libs[lib_name] = True
            
    for lib, found in found_libs.items():
        if not found:
            print_warning(f"  [WARNING] Could not find host {lib}!")

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
                    subprocess.run(f"cp -an {s} {d}", shell=True, executable="/usr/bin/bash")
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
        "bin/gsh",
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
        "usr/share/fonts/TTF/Inter-Regular.otf"
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

    # 5. Final Integrity Check
    if not verify_rootfs_integrity():
        print_error("FATAL: Final rootfs integrity check failed!")
        sys.exit(1)

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
    # Resolve dependencies
    result = subprocess.run(f"ldd {binary_path}", shell=True, capture_output=True, text=True, executable="/usr/bin/bash")
    interpreter_names = ["ld-linux-x86-64.so.2"]
    for line in result.stdout.splitlines():
        lib_path = ""
        if "=>" in line:
            parts = line.split("=>")
            lib_path_info = parts[1].strip()
            if "(" in lib_path_info:
                lib_path = lib_path_info.split("(")[0].strip()
            else:
                lib_path = lib_path_info
        elif line.strip().startswith("/"):
            lib_path_info = line.strip()
            if "(" in lib_path_info:
                lib_path = lib_path_info.split("(")[0].strip()
            else:
                lib_path = lib_path_info
        if not lib_path: continue
        lib_filename = os.path.basename(lib_path)
    
        # Search in common lib locations in rootfs
        found = False
        for search_path in ["lib64", "usr/lib64", "lib", "usr/lib"]:
            candidate = os.path.join(rootfs_dir, search_path, lib_filename)
            if os.path.exists(candidate):
                # Always copy to /lib64 in initramfs work_dir
                dest_lib_dir = os.path.join(dest_dir, "lib64")
                os.makedirs(dest_lib_dir, exist_ok=True)
                real_lib = os.path.realpath(candidate)
                shutil.copy2(real_lib, os.path.join(dest_lib_dir, os.path.basename(real_lib)))
                if real_lib != candidate:
                    link_name = os.path.join(dest_lib_dir, lib_filename)
                    if os.path.exists(link_name): os.remove(link_name)
                    os.symlink(os.path.basename(real_lib), link_name)
                found = True
                break

        if not found and "vdso" not in line:
            print_warning(f"WARNING: Could not find library {lib_filename} in rootfs for {binary_path}")
    # Extra check for interpreter
    for interp in interpreter_names:
        if not os.path.exists(os.path.join(dest_dir, "lib64", interp)):
             for search_path in ["lib64", "usr/lib64", "lib", "usr/lib"]:
                 src_interp = os.path.join(rootfs_dir, search_path, interp)
                 if os.path.exists(src_interp):
                     dest_lib_dir = os.path.join(dest_dir, "lib64")
                     os.makedirs(dest_lib_dir, exist_ok=True)
                     shutil.copy2(src_interp, os.path.join(dest_lib_dir, interp))
                     break
    return True

def create_minimal_initramfs():
    print_section("\n=== Building Minimal Initramfs (Live CD Bootloader) ===")
    
    work_dir = os.path.join(ROOT_DIR, "initramfs_build")
    if os.path.exists(work_dir):
        shutil.rmtree(work_dir)
    os.makedirs(work_dir)
    
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
echo \"Switching to real root...\"
exec switch_root /new_root /bin/init
"""
    with open(os.path.join(work_dir, "init"), "w") as f:
        f.write(init_script)
    os.chmod(os.path.join(work_dir, "init"), 0o755)
    
    # Pack it
    print_info("[*] Compressing minimal initramfs...")
    os.makedirs(os.path.join(ROOT_DIR, "isodir/boot"), exist_ok=True)
    
    pack_cmd = (
        f"cd {work_dir} && "
        "find . -print0 | cpio --null -o --format=newc | lz4 -l -T0 > ../isodir/boot/initramfs.cpio.lz4"
    )
    run_command(pack_cmd)
    
    return True

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
        
    # Using zstd for speed/compression balance
    mksquashfs_cmd = f"mksquashfs rootfs {sfs_path} -comp zstd -noappend -wildcards -all-root"
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
    linux /boot/kernel console=tty0 console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200
    initrd /boot/initramfs.cpio.lz4
}
"""
    with open("isodir/boot/grub/grub.cfg", "w") as f:
        f.write(grub_conf)

    # 5. Build ISO
    print_info("[*] Building GeminiOS.iso...")
    iso_cmd = "grub-mkrescue -o GeminiOS.iso isodir"
    if run_command(iso_cmd) != 0:
        print_error(" [FAILED] (grub-mkrescue)")
        return False

    print_success("[!] ISO built successfully: GeminiOS.iso")
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
    
    # Filter out flags to get requested packages
    requested_packages = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    
    packages_to_build = []
    if requested_packages:
        # Build only requested packages that exist in the PACKAGES list
        for pkg in requested_packages:
            if pkg in PACKAGES:
                packages_to_build.append(pkg)
            else:
                print_warning(f"WARNING: Package '{pkg}' not found in PACKAGES list.")
        
        if not packages_to_build:
            print_error("ERROR: No valid packages specified to build.")
            sys.exit(1)
    else:
        # Build everything
        packages_to_build = PACKAGES

    print_section("=== GeminiOS Ports Builder ===")
    
    total_pkgs = len(packages_to_build)
    for i, pkg in enumerate(packages_to_build, 1):
        if not build_package(pkg, i, total_pkgs, force=force_rebuild, debug=debug_mode):
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

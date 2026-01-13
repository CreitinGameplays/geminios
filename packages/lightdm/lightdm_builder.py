#!/usr/bin/env python3
import os
import sys
import subprocess
import shutil
import json
import tarfile
import urllib.request
import time

# Terminal Colors
class Colors:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    CYAN = "\033[96m"
    BLUE = "\033[94m"
    MAGENTA = "\033[95m"

def color(text, color_code):
    return f"{color_code}{text}{Colors.RESET}"

# Configuration
LIGHTDM_VERSION = "1.32.0"
ROOT_DIR = os.getcwd()
PACKAGES_DIR = os.path.join(ROOT_DIR, "packages/lightdm")
EXPORT_DIR = os.path.join(ROOT_DIR, "export/x86_64/lightdm")
LOG_DIR = os.path.join(ROOT_DIR, "logs/lightdm")
STAGING_DIR = os.path.join(ROOT_DIR, "rootfs/staging/lightdm")
BUILD_SYSTEM_DIR = os.path.join(ROOT_DIR, "build_system")
TARGET_ENV_SCRIPT = os.path.join(BUILD_SYSTEM_DIR, "target_env.sh")
ENV_CONFIG_SCRIPT = os.path.join(BUILD_SYSTEM_DIR, "env_config.sh")

# Ensure directories exist
os.makedirs(EXPORT_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(STAGING_DIR, exist_ok=True)

# Package Definitions
PACKAGES = [
    {
        "name": "libgpg-error",
        "version": "1.47",
        "desc": "Library that defines common error values for all GnuPG components",
        "url": "https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.47.tar.bz2"
    },
    {
        "name": "libgcrypt",
        "version": "1.10.3",
        "desc": "General purpose crypto library based on the code used in GnuPG",
        "url": "https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.10.3.tar.bz2",
        "depends": ["libgpg-error"]
    },
    {
        "name": "linux-pam",
        "version": "1.5.3",
        "desc": "Pluggable Authentication Modules for Linux",
        "url": "https://github.com/linux-pam/linux-pam/releases/download/v1.5.3/Linux-PAM-1.5.3.tar.xz",
        "depends": []
    },
    {
        "name": "iso-codes",
        "version": "4.15.0",
        "desc": "ISO language, territory, currency, script codes and their translations",
        "url": "https://ftp.debian.org/debian/pool/main/i/iso-codes/iso-codes_4.15.0.orig.tar.xz",
        "depends": []
    },
    {
        "name": "libxklavier",
        "version": "5.4",
        "desc": "High-level API for X Keyboard Extension",
        "url": "https://people.freedesktop.org/~svu/libxklavier-5.4.tar.bz2",
        "depends": ["glib", "libxml2", "libxi", "iso-codes"]
    },
    {
        "name": "lightdm",
        "version": "1.32.0",
        "desc": "Lightweight Display Manager",
        "url": "https://github.com/canonical/lightdm/releases/download/1.32.0/lightdm-1.32.0.tar.xz",
        "depends": ["linux-pam", "libxcb", "glib", "libgcrypt", "libxklavier"]
    },
    {
        "name": "xfce4-dev-tools",
        "version": "4.18.0",
        "desc": "Xfce developer tools",
        "url": "https://archive.xfce.org/src/xfce/xfce4-dev-tools/4.18/xfce4-dev-tools-4.18.0.tar.bz2",
        "depends": ["glib"]
    },
    {
        "name": "lightdm-gtk-greeter",
        "version": "2.0.8",
        "desc": "GTK+ greeter for LightDM",
        "url": "https://github.com/Xubuntu/lightdm-gtk-greeter/releases/download/lightdm-gtk-greeter-2.0.8/lightdm-gtk-greeter-2.0.8.tar.gz",
        "depends": ["lightdm", "gtk3"]
    }
]

def run_shell(cmd, cwd=None, log_file=None):
    wrapped_cmd = f"source {ENV_CONFIG_SCRIPT} && source {TARGET_ENV_SCRIPT} && {cmd}"
    if log_file:
        with open(log_file, "a") as f:
            f.write(f"\nCMD: {cmd}\n")
            p = subprocess.run(wrapped_cmd, shell=True, executable="/bin/bash", cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    else:
        p = subprocess.run(wrapped_cmd, shell=True, executable="/bin/bash", cwd=cwd)
    return p.returncode

def download_file(url, dest):
    if not url: return
    if os.path.exists(dest): return
    print(f"  Downloading {url}...")
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req) as response, open(dest, 'wb') as out_file:
            shutil.copyfileobj(response, out_file)
    except Exception as e:
        print(color(f"  [ERROR] Download failed: {e}", Colors.RED))
        if os.path.exists(dest): os.remove(dest)
        sys.exit(1)

def is_built(pkg):
    gpkg_name = f"{pkg['name']}_{pkg['version']}_x86_64.gpkg"
    gpkg_path = os.path.join(EXPORT_DIR, gpkg_name)
    
    # Also check if it's in staging (except for iso-codes which might just be data)
    staging_check = True
    if pkg['name'] != "iso-codes":
        # Check for a representative file in staging, like a .pc file or a main header/lib
        # This is a bit simplified
        pass

    return os.path.exists(gpkg_path)

def build_package(pkg, force=False):
    name = pkg["name"]
    version = pkg["version"]
    url = pkg.get("url", "")
    pkg_full_name = f"{name}-{version}"
    work_dir = os.path.join(PACKAGES_DIR, name)
    src_dir = os.path.join(work_dir, pkg_full_name)
    install_dir = os.path.join(work_dir, "root")
    log_file = os.path.join(LOG_DIR, f"{name}.log")
    
    gpkg_name = f"{name}_{version}_x86_64.gpkg"
    gpkg_path = os.path.join(EXPORT_DIR, gpkg_name)

    if not force and is_built(pkg):
        print(color(f"=== Skipping {name} {version} (Already Built) ===", Colors.CYAN))
        return True

    print(color(f"=== Building {name} {version} ===", Colors.BOLD + Colors.MAGENTA))
    start_time = time.time()
    
    os.makedirs(work_dir, exist_ok=True)
    if os.path.exists(install_dir): shutil.rmtree(install_dir)
    os.makedirs(install_dir)
    
    tarball = os.path.join(work_dir, os.path.basename(url))
    download_file(url, tarball)
    
    if os.path.exists(src_dir): shutil.rmtree(src_dir)
    
    # Handle special source directory names
    print("  Extracting...")
    subprocess.run(f"tar -xf {tarball} -C {work_dir}", shell=True, check=True)
    
    # Some packages have different folder names in tarball
    if name == "linux-pam" and not os.path.exists(src_dir):
        possible_dir = os.path.join(work_dir, f"Linux-PAM-{version}")
        if os.path.exists(possible_dir): os.rename(possible_dir, src_dir)
    elif name == "iso-codes" and not os.path.exists(src_dir):
        possible_dir = os.path.join(work_dir, f"iso-codes-{version}")
        if os.path.exists(possible_dir): os.rename(possible_dir, src_dir)

    xfce_staging_dir = os.path.join(ROOT_DIR, "packages/xfce/staging")
    
    def get_existing_paths(base_staging, subpaths):
        paths = []
        for p in subpaths:
            full_path = os.path.join(base_staging, p)
            if os.path.exists(full_path):
                paths.append(full_path)
        return paths

    staging_paths = {
        "bin": get_existing_paths(STAGING_DIR, ["usr/bin", "bin", "usr/sbin", "sbin"]),
        "pkgconfig": get_existing_paths(STAGING_DIR, ["usr/lib/pkgconfig", "usr/lib64/pkgconfig", "usr/share/pkgconfig", "lib/pkgconfig", "lib64/pkgconfig"]),
        "include": get_existing_paths(STAGING_DIR, ["usr/include"]),
        "lib": get_existing_paths(STAGING_DIR, ["usr/lib", "usr/lib64", "lib", "lib64"]),
        "share": get_existing_paths(STAGING_DIR, ["usr/share"])
    }

    xfce_paths = {
        "bin": get_existing_paths(xfce_staging_dir, ["usr/bin", "bin"]) if os.path.exists(xfce_staging_dir) else [],
        "pkgconfig": get_existing_paths(xfce_staging_dir, ["usr/lib/pkgconfig", "usr/lib64/pkgconfig", "usr/share/pkgconfig"]) if os.path.exists(xfce_staging_dir) else [],
        "include": get_existing_paths(xfce_staging_dir, ["usr/include"]) if os.path.exists(xfce_staging_dir) else [],
        "lib": get_existing_paths(xfce_staging_dir, ["usr/lib", "usr/lib64"]) if os.path.exists(xfce_staging_dir) else [],
        "share": get_existing_paths(xfce_staging_dir, ["usr/share"]) if os.path.exists(xfce_staging_dir) else []
    }

    # Calculate paths relative to ROOTFS for sysroot compatibility
    rootfs_path = os.path.join(ROOT_DIR, "rootfs")
    def to_sysroot_path(abs_path, prefix="/"):
        rel = os.path.relpath(abs_path, rootfs_path)
        # Ensure we have a leading slash after prefix if prefix is '='
        if prefix == "=":
            return "=/" + rel
        return prefix + rel

    path_dirs = staging_paths["bin"] + xfce_paths["bin"]
    pkg_config_dirs = staging_paths["pkgconfig"] + xfce_paths["pkgconfig"]
    
    # Use absolute host paths for CFLAGS and LDFLAGS during build
    # This is more reliable than sysroot-relative paths which can be mangled by libtool
    cflags_dirs = staging_paths["include"] + xfce_paths["include"]
    ldflags_dirs = staging_paths["lib"] + xfce_paths["lib"]
    xdg_data_dirs = staging_paths["share"] + xfce_paths["share"]
    ld_library_dirs = staging_paths["lib"] + xfce_paths["lib"]

    # We use PKG_CONFIG_SYSROOT_DIR=$ROOTFS to ensure that system packages (from rootfs)
    # return paths prefixed with the rootfs path.
    env_vars = (
        f"export PKG_CONFIG=/usr/bin/pkg-config && "
        f"export PATH={':'.join(path_dirs)}:$PATH && "
        f"export PKG_CONFIG_PATH={':'.join(pkg_config_dirs)}:$PKG_CONFIG_PATH && "
        f"export PKG_CONFIG_SYSROOT_DIR=\"$ROOTFS\" && "
        f"export PKG_CONFIG_LIBDIR=\"$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig\" && "
        f"export CFLAGS=\"{' '.join(['-I' + d for d in cflags_dirs])} $CFLAGS -Wno-error=missing-include-dirs\" && "
        f"export LDFLAGS=\"{' '.join(['-L' + d for d in ldflags_dirs])} {' '.join(['-Wl,-rpath-link,' + d for d in ldflags_dirs])} $LDFLAGS\" && "

        f"export XDG_DATA_DIRS={':'.join(xdg_data_dirs)}:$XDG_DATA_DIRS && "
        f"export LD_LIBRARY_PATH={':'.join(ld_library_dirs)}:$LD_LIBRARY_PATH"
    )

    
    configure_flags = "--prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static"
    if name == "libgcrypt":
        configure_flags += f" --with-libgpg-error-prefix={STAGING_DIR}/usr"
    elif name == "linux-pam":
        configure_flags += " --disable-regenerate-docu --enable-securedir=/lib/security --disable-selinux --disable-audit"
    elif name == "libxklavier":
        configure_flags += " --disable-introspection --with-xkb-base=/usr/share/X11/xkb"
    elif name == "lightdm":
        configure_flags += " --disable-introspection --disable-tests --with-user-session=xfce --with-greeter-session=lightdm-gtk-greeter ITSTOOL=true XMLLINT=true --disable-werror"
    elif name == "lightdm-gtk-greeter":
        configure_flags += " --disable-indicator-services-command"
    
    if "disable-introspection" not in configure_flags and name not in ["linux-pam", "libgcrypt", "libgpg-error", "iso-codes"]:
         configure_flags += " --disable-introspection"

    print("  Configuring...")
    if run_shell(f"{env_vars} && ./configure {configure_flags}", cwd=src_dir, log_file=log_file) != 0:
        print(color(f"  [ERROR] Configure failed. Check {log_file}", Colors.RED))
        return False
    
    print("  Compiling...")
    make_cmd = "make -j$(nproc)"
    if name == "libxklavier":
        make_cmd += " V=1"
    if run_shell(f"{env_vars} && {make_cmd}", cwd=src_dir, log_file=log_file) != 0:
        print(color(f"  [ERROR] Make failed. Check {log_file}", Colors.RED))
        return False
    
    print("  Installing...")
    run_shell(f"make DESTDIR={install_dir} install", cwd=src_dir, log_file=log_file)
    run_shell(f"make DESTDIR={STAGING_DIR} install", cwd=src_dir, log_file=log_file)
    subprocess.run(f"find {STAGING_DIR} -name '*.la' -delete", shell=True)
    
    print("  Fixing .pc files in staging...")
    rel_staging_usr = to_sysroot_path(os.path.join(STAGING_DIR, "usr"))
    rel_staging_lib = to_sysroot_path(os.path.join(STAGING_DIR, "lib"))
    for root, dirs, files in os.walk(STAGING_DIR):
        for file in files:
            if file.endswith(".pc"):
                pc_path = os.path.join(root, file)
                subprocess.run(f"sed -i 's|^prefix=.*|prefix={rel_staging_usr}|' {pc_path}", shell=True)
                subprocess.run(f"sed -i 's|^libdir=/lib|libdir={rel_staging_lib}|' {pc_path}", shell=True)
                subprocess.run(f"sed -i 's|^includedir=/usr|includedir={rel_staging_usr}|' {pc_path}", shell=True)


    
    print("  Creating control.json...")
    control_data = {"package": name, "version": version, "architecture": "x86_64", "maintainer": "GeminiOS User", "description": pkg["desc"], "depends": pkg.get("depends", [])}
    with open(os.path.join(work_dir, "control.json"), "w") as f:
        json.dump(control_data, f, indent=2)
    
    print("  Packaging...")
    import tempfile
    with tempfile.TemporaryDirectory() as tmp_dir:
        data_tar = os.path.join(tmp_dir, "data.tar")
        subprocess.run(f"tar -cf {data_tar} -C {install_dir} .", shell=True, check=True)
        data_tar_zst = os.path.join(tmp_dir, "data.tar.zst")
        subprocess.run(f"zstd -q -f {data_tar} -o {data_tar_zst}", shell=True, check=True)
        final_tar = os.path.join(tmp_dir, "final.tar")
        with tarfile.open(final_tar, "w") as tar:
            tar.add(os.path.join(work_dir, "control.json"), arcname="control.json")
            tar.add(data_tar_zst, arcname="data.tar.zst")
        subprocess.run(f"zstd -q -f {final_tar} -o {gpkg_path}", shell=True, check=True)
    
    duration = time.time() - start_time
    print(color(f"  [DONE] Created {gpkg_path} ({duration:.2f}s)", Colors.GREEN))
    return True

def update_repo_index():
    print(color("\n=== Updating Repository Index ===", Colors.BOLD + Colors.MAGENTA))
    scanrepo_script = "/home/creitin/Documents/geminios-sdk/gpkg_scanrepo.py"
    repo_root = os.path.abspath(os.path.join(EXPORT_DIR, ".."))
    if os.path.exists(scanrepo_script):
        subprocess.run([sys.executable, scanrepo_script, repo_root], check=True)

def main():
    force = "--force" in sys.argv
    print(color("Starting LightDM Build", Colors.BOLD + Colors.BLUE))
    for pkg in PACKAGES:
        if not build_package(pkg, force=force): sys.exit(1)
    update_repo_index()
    print(color("\nLightDM stack built successfully!", Colors.BOLD + Colors.GREEN))

if __name__ == "__main__":
    main()

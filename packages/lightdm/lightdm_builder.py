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
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../"))
PACKAGES_DIR = os.path.join(ROOT_DIR, "packages/lightdm")
EXPORT_DIR = os.path.join(ROOT_DIR, "export/x86_64/lightdm")
LOG_DIR = os.path.join(ROOT_DIR, "logs/lightdm")
STAGING_DIR = os.path.join(ROOT_DIR, "packages/lightdm/staging/lightdm")
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
        "name": "duktape",
        "version": "2.7.0",
        "desc": "Embeddable Javascript engine",
        "url": "https://duktape.org/duktape-2.7.0.tar.xz",
        "depends": []
    },
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
        "name": "libcap",
        "version": "2.69",
        "desc": "POSIX 1003.1e capabilities",
        "url": "https://mirrors.edge.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.69.tar.xz",
        "depends": []
    },
    {
        "name": "MarkupSafe",
        "version": "2.1.5",
        "desc": "Safely add untrusted strings to HTML/XML markup.",
        "url": "https://files.pythonhosted.org/packages/source/M/MarkupSafe/MarkupSafe-2.1.5.tar.gz",
        "depends": []
    },
    {
        "name": "Jinja2",
        "version": "3.1.3",
        "desc": "A very fast and expressive template engine.",
        "url": "https://files.pythonhosted.org/packages/source/J/Jinja2/Jinja2-3.1.3.tar.gz",
        "depends": []
    },
    {
        "name": "elogind",
        "version": "252.9",
        "desc": "The systemd project's logind, extracted to a standalone package",
        "url": "https://github.com/elogind/elogind/archive/v252.9/elogind-252.9.tar.gz",
        "depends": ["linux-pam", "libcap"]
    },
    {
        "name": "polkit",
        "version": "124",
        "desc": "Toolkit for controlling system-wide privileges",
        "url": "https://github.com/polkit-org/polkit/archive/124/polkit-124.tar.gz",
        "depends": ["duktape", "linux-pam", "elogind", "libcap"]
    },
    {
        "name": "accountsservice",
        "version": "23.13.9",
        "desc": "D-Bus interface for querying and manipulating user account information",
        "url": "https://www.freedesktop.org/software/accountsservice/accountsservice-23.13.9.tar.xz",
        "depends": ["polkit"]
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
        "depends": ["iso-codes"]
    },
    {
        "name": "lightdm",
        "version": "1.32.0",
        "desc": "Lightweight Display Manager",
        "url": "https://github.com/canonical/lightdm/releases/download/1.32.0/lightdm-1.32.0.tar.xz",
        "depends": ["linux-pam", "libgcrypt", "libxklavier", "lightdm-gtk-greeter", "accountsservice", "elogind"] 
    },
    {
        "name": "xfce4-dev-tools",
        "version": "4.18.0",
        "desc": "Xfce developer tools",
        "url": "https://archive.xfce.org/src/xfce/xfce4-dev-tools/4.18/xfce4-dev-tools-4.18.0.tar.bz2",
        "depends": []
    },
    {
        "name": "lightdm-gtk-greeter",
        "version": "2.0.8",
        "desc": "GTK+ greeter for LightDM",
        "url": "https://github.com/Xubuntu/lightdm-gtk-greeter/releases/download/lightdm-gtk-greeter-2.0.8/lightdm-gtk-greeter-2.0.8.tar.gz",
        "depends": ["lightdm"]
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
    rootfs_path = os.path.join(ROOT_DIR, "rootfs")
    
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
    elif name == "polkit" and not os.path.exists(src_dir):
        possible_dir = os.path.join(work_dir, f"polkit-{version}")
        if os.path.exists(possible_dir): os.rename(possible_dir, src_dir)
    elif name == "libcap" and not os.path.exists(src_dir):
        possible_dir = os.path.join(work_dir, f"libcap-{version}")
        if os.path.exists(possible_dir): os.rename(possible_dir, src_dir)
    elif name == "elogind" and not os.path.exists(src_dir):
        possible_dir = os.path.join(work_dir, f"elogind-{version}")
        if os.path.exists(possible_dir): os.rename(possible_dir, src_dir)

    if name == "polkit":
        meson_file = os.path.join(src_dir, "meson.build")
        if os.path.exists(meson_file):
            print("  Patching polkit meson.build...")
            with open(meson_file, "r") as f:
                content = f.read()
            # Fix systemd_dep unknown variable
            old_code = "systemd_sysusers_dir = systemd_dep.get_pkgconfig_variable('sysusers_dir', default: '/usr/lib/sysusers.d')"
            new_code = "systemd_sysusers_dir = '/usr/lib/sysusers.d'"
            content = content.replace(old_code, new_code)
            with open(meson_file, "w") as f:
                f.write(content)

    if name == "accountsservice":
        meson_file = os.path.join(src_dir, "meson.build")
        if os.path.exists(meson_file):
            print("  Patching accountsservice meson.build to disable tests...")
            with open(meson_file, "r") as f:
                content = f.read()
            content = content.replace("subdir('tests')", "# subdir('tests')")
            with open(meson_file, "w") as f:
                f.write(content)

    if name in ["polkit", "accountsservice", "elogind"]:
        # Create symlinks to system tools to bypass shims or rootfs versions
        bypass_bin_dir = os.path.join(work_dir, "bypass_bin")
        os.makedirs(bypass_bin_dir, exist_ok=True)
        
        # Python3: Bypass shim to preserve PYTHONPATH
        python3_shim = os.path.join(bypass_bin_dir, "python3")
        if os.path.lexists(python3_shim): os.remove(python3_shim)
        target_python = sys.executable if sys.executable else "/usr/bin/python3"
        os.symlink(target_python, python3_shim)
        
        # g-ir-scanner: Use host version but with clean PYTHONPATH and LD_LIBRARY_PATH
        scanner_shim = os.path.join(bypass_bin_dir, "g-ir-scanner")
        if os.path.lexists(scanner_shim): os.remove(scanner_shim)
        with open(scanner_shim, "w") as f:
            f.write("#!/bin/sh\nunset PYTHONPATH\nunset LD_LIBRARY_PATH\nexec /usr/bin/g-ir-scanner \"$@\"\n")
        os.chmod(scanner_shim, 0o755)

        # g-ir-compiler: Same for consistency
        compiler_shim = os.path.join(bypass_bin_dir, "g-ir-compiler")
        if os.path.lexists(compiler_shim): os.remove(compiler_shim)
        with open(compiler_shim, "w") as f:
            f.write("#!/bin/sh\nunset PYTHONPATH\nunset LD_LIBRARY_PATH\nexec /usr/bin/g-ir-compiler \"$@\"\n")
        os.chmod(compiler_shim, 0o755)

        # Patch gobject-introspection-1.0.pc to use our shims
        pc_file = os.path.join(rootfs_path, "usr/lib64/pkgconfig/gobject-introspection-1.0.pc")
        if os.path.exists(pc_file):
             print(f"  Patching gobject-introspection-1.0.pc for {name}...")
             with open(pc_file, "r") as f:
                 pc_content = f.read()
             
             # Calculate relative path from ROOTFS to bypass_bin_dir
             rel_path = os.path.relpath(bypass_bin_dir, rootfs_path)
             # Use ${pc_sysrootdir} to allow pkg-config to resolve the path relative to sysroot
             # This bypasses the issue where pkg-config prepends sysroot to absolute paths
             shim_scanner_var = "${pc_sysrootdir}/" + os.path.join(rel_path, "g-ir-scanner")
             shim_compiler_var = "${pc_sysrootdir}/" + os.path.join(rel_path, "g-ir-compiler")
             
             import re
             pc_content = re.sub(r"^g_ir_scanner=.*", f"g_ir_scanner={shim_scanner_var}", pc_content, flags=re.MULTILINE)
             pc_content = re.sub(r"^g_ir_compiler=.*", f"g_ir_compiler={shim_compiler_var}", pc_content, flags=re.MULTILINE)
             with open(pc_file, "w") as f:
                 f.write(pc_content)

        # Also patch in staging if it exists (it might shadow rootfs)
        staging_pc = os.path.join(STAGING_DIR, "usr/lib/pkgconfig/gobject-introspection-1.0.pc")
        if not os.path.exists(staging_pc):
             staging_pc = os.path.join(STAGING_DIR, "usr/lib64/pkgconfig/gobject-introspection-1.0.pc")
        
        if os.path.exists(staging_pc):
             print(f"  Patching gobject-introspection-1.0.pc in STAGING for {name}...")
             with open(staging_pc, "r") as f:
                 pc_content = f.read()
             
             # Relative path logic same as above
             rel_path = os.path.relpath(bypass_bin_dir, rootfs_path)
             shim_scanner_var = "${pc_sysrootdir}/" + os.path.join(rel_path, "g-ir-scanner")
             shim_compiler_var = "${pc_sysrootdir}/" + os.path.join(rel_path, "g-ir-compiler")

             import re
             pc_content = re.sub(r"^g_ir_scanner=.*", f"g_ir_scanner={shim_scanner_var}", pc_content, flags=re.MULTILINE)
             pc_content = re.sub(r"^g_ir_compiler=.*", f"g_ir_compiler={shim_compiler_var}", pc_content, flags=re.MULTILINE)
             with open(staging_pc, "w") as f:
                 f.write(pc_content)

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

    # Python Staging Paths
    staging_python = get_existing_paths(STAGING_DIR, ["usr/lib/python3.11/site-packages", "usr/lib64/python3.11/site-packages"])
    xfce_python = get_existing_paths(xfce_staging_dir, ["usr/lib/python3.11/site-packages", "usr/lib64/python3.11/site-packages"]) if os.path.exists(xfce_staging_dir) else []
    python_path_dirs = staging_python + xfce_python

    # Calculate paths relative to ROOTFS for sysroot compatibility
    def to_sysroot_path(abs_path, prefix="/"):
        rel = os.path.relpath(abs_path, rootfs_path)
        if prefix == "=":
            return "=/" + rel
        return prefix + rel

    path_dirs = staging_paths["bin"] + xfce_paths["bin"]
    if name in ["polkit", "accountsservice", "elogind"]:
         bypass_bin_dir = os.path.join(work_dir, "bypass_bin")
         path_dirs.insert(0, bypass_bin_dir)

    pkg_config_dirs = staging_paths["pkgconfig"] + xfce_paths["pkgconfig"]
    
    cflags_dirs = staging_paths["include"] + xfce_paths["include"]
    ldflags_dirs = staging_paths["lib"] + xfce_paths["lib"]
    xdg_data_dirs = staging_paths["share"] + xfce_paths["share"]
    ld_library_dirs = staging_paths["lib"] + xfce_paths["lib"]

    env_vars = (
        f"export PKG_CONFIG=/usr/bin/pkg-config && "
        f"export PATH={':'.join(path_dirs)}:$PATH && "
        f"export PKG_CONFIG_PATH={':'.join(pkg_config_dirs)}:$PKG_CONFIG_PATH && "
        f"export PKG_CONFIG_SYSROOT_DIR=\"$ROOTFS\" && "
        f"export PKG_CONFIG_LIBDIR=\"$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/share/pkgconfig\" && "
        f"export CFLAGS=\"{' '.join(['-I' + d for d in cflags_dirs])} $CFLAGS -Wno-error=missing-include-dirs\" && "
        f"export LDFLAGS=\"{' '.join(['-L' + d for d in ldflags_dirs])} {' '.join(['-Wl,-rpath-link,' + d for d in ldflags_dirs])} $LDFLAGS\" && "
        f"export XDG_DATA_DIRS={':'.join(xdg_data_dirs)}:$XDG_DATA_DIRS && "
        f"export LD_LIBRARY_PATH={':'.join(ld_library_dirs)}:$LD_LIBRARY_PATH && "
        f"export PYTHONPATH={':'.join(python_path_dirs)}:$PYTHONPATH"
    )

    # Special case for Duktape
    if name == "duktape":
        print("  Compiling Duktape...")
        if run_shell(f"{env_vars} && make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr LIBDIR=/lib64", cwd=src_dir, log_file=log_file) != 0:
            print(color(f"  [ERROR] Make failed. Check {log_file}", Colors.RED))
            return False
        print("  Installing Duktape...")
        run_shell(f"make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr LIBDIR=/lib64 DESTDIR={install_dir} install", cwd=src_dir, log_file=log_file)
        run_shell(f"make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr LIBDIR=/lib64 DESTDIR={STAGING_DIR} install", cwd=src_dir, log_file=log_file)
        
        # Create duktape.pc
        pc_content = f"""
prefix=/usr
exec_prefix=${{prefix}}
libdir=${{exec_prefix}}/lib64
includedir=${{prefix}}/include

Name: duktape
Description: Duktape is an embeddable Javascript engine
Version: {version}
Libs: -L${{libdir}} -lduktape
Cflags: -I${{includedir}}
"""
        os.makedirs(os.path.join(install_dir, "usr/lib64/pkgconfig"), exist_ok=True)
        with open(os.path.join(install_dir, "usr/lib64/pkgconfig/duktape.pc"), "w") as f:
            f.write(pc_content)
        
        os.makedirs(os.path.join(STAGING_DIR, "usr/lib64/pkgconfig"), exist_ok=True)
        with open(os.path.join(STAGING_DIR, "usr/lib64/pkgconfig/duktape.pc"), "w") as f:
            f.write(pc_content)
            
    elif name == "libcap":
        print("  Compiling libcap...")
        if run_shell(f"{env_vars} && make prefix=/usr lib=lib64", cwd=src_dir, log_file=log_file) != 0:
            print(color(f"  [ERROR] Make failed. Check {log_file}", Colors.RED))
            return False
        print("  Installing libcap...")
        run_shell(f"make prefix=/usr lib=lib64 DESTDIR={install_dir} install", cwd=src_dir, log_file=log_file)
        run_shell(f"make prefix=/usr lib=lib64 DESTDIR={STAGING_DIR} install", cwd=src_dir, log_file=log_file)
    
    # Check for setup.py (Python Packages)
    elif os.path.exists(os.path.join(src_dir, "setup.py")):
        print("  Installing Python package...")
        if run_shell(f"{env_vars} && python3 setup.py install --root={install_dir} --prefix=/usr --optimize=1", cwd=src_dir, log_file=log_file) != 0:
             print(color(f"  [ERROR] Python install failed. Check {log_file}", Colors.RED))
             return False
        run_shell(f"{env_vars} && python3 setup.py install --root={STAGING_DIR} --prefix=/usr --optimize=1", cwd=src_dir, log_file=log_file)

    # Check for Meson
    elif os.path.exists(os.path.join(src_dir, "meson.build")):
        print("  Configuring with Meson...")
        # Clean build directory to force fresh reconfiguration/cache
        build_dir = os.path.join(src_dir, "build")
        if os.path.exists(build_dir):
            shutil.rmtree(build_dir)
            
        meson_flags = "--prefix=/usr --sysconfdir=/etc --localstatedir=/var --libdir=lib64"
        if name == "polkit":
             meson_flags += " -Dsession_tracking=libelogind -Dtests=false -Dman=false -Dintrospection=false -Dexamples=false"
        elif name == "accountsservice":
             meson_flags += " -Dadmin_group=wheel -Ddocbook=false -Dintrospection=false -Dsystemdsystemunitdir=no -Delogind=true"
        elif name == "elogind":
             meson_flags += " -Dman=false -Dtests=false -Dpamlibdir=/lib/security"
        
        if run_shell(f"{env_vars} && meson setup build {meson_flags}", cwd=src_dir, log_file=log_file) != 0:
             print(color(f"  [ERROR] Meson configure failed. Check {log_file}", Colors.RED))
             return False
        
        print("  Compiling with Ninja...")
        if run_shell(f"{env_vars} && ninja -C build", cwd=src_dir, log_file=log_file) != 0:
             print(color(f"  [ERROR] Ninja failed. Check {log_file}", Colors.RED))
             return False
             
        print("  Installing...")
        run_shell(f"{env_vars} && DESTDIR={install_dir} ninja -C build install", cwd=src_dir, log_file=log_file)
        run_shell(f"{env_vars} && DESTDIR={STAGING_DIR} ninja -C build install", cwd=src_dir, log_file=log_file)

        # Fix for elogind installing into absolute path
        if name == "elogind":
            # Check if it installed into nested rootfs path (remove leading slash for join)
            nested_root = os.path.join(install_dir, rootfs_path.lstrip("/"))
            if os.path.exists(nested_root):
                print(f"  Fixing nested installation paths for elogind in {install_dir}...")
                # Move contents to correct place
                subprocess.run(f"cp -a {nested_root}/* {install_dir}/", shell=True)
                # Remove the nested directory structure
                # We need to remove the top-level directory that shouldn't be there (e.g., 'home' or 'mnt')
                # The first component of rootfs_path relative to root
                first_dir = rootfs_path.strip("/").split("/")[0]
                subprocess.run(f"rm -rf {os.path.join(install_dir, first_dir)}", shell=True)
            
            # Same for staging
            nested_staging = os.path.join(STAGING_DIR, rootfs_path.lstrip("/"))
            if os.path.exists(nested_staging):
                print(f"  Fixing nested installation paths for elogind in {STAGING_DIR}...")
                subprocess.run(f"cp -a {nested_staging}/* {STAGING_DIR}/", shell=True)
                first_dir = rootfs_path.strip("/").split("/")[0]
                subprocess.run(f"rm -rf {os.path.join(STAGING_DIR, first_dir)}", shell=True)
    
    else:
        # Standard Configure/Make
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
    
    # Common Post-Install Steps
    # Remove /usr/share/info/dir to avoid conflicts between packages
    subprocess.run(f"rm -f {install_dir}/usr/share/info/dir", shell=True)
    subprocess.run(f"rm -f {STAGING_DIR}/usr/share/info/dir", shell=True)
    
    # Configure LightDM for GeminiOS (No logind)
    if name == "lightdm":
        conf_path = os.path.join(install_dir, "etc/lightdm/lightdm.conf")
        if os.path.exists(conf_path):
            subprocess.run(f"sed -i 's/#logind-check-graphical=true/logind-check-graphical=false/' {conf_path}", shell=True)
            subprocess.run(f"sed -i 's/#greeter-session=example-gtk-gnome/greeter-session=lightdm-gtk-greeter/' {conf_path}", shell=True)
            subprocess.run(f"sed -i 's/#user-session=default/user-session=xfce/' {conf_path}", shell=True)
            subprocess.run(f"sed -i 's/#greeter-user=lightdm/greeter-user=lightdm/' {conf_path}", shell=True)
            subprocess.run(f"sed -i 's/#log-level=info/log-level=debug/' {conf_path}", shell=True)

        # Configure PAM for LightDM
        pam_dir = os.path.join(install_dir, "etc/pam.d")
        os.makedirs(pam_dir, exist_ok=True)

        # 1. lightdm (Main Service) - Use GeminiOS common-* files
        print(f"  Generating PAM config: {os.path.join(pam_dir, 'lightdm')}")
        with open(os.path.join(pam_dir, "lightdm"), "w") as f:
            f.write("#%PAM-1.0\n")
            f.write("# Load environment from /etc/environment and ~/.pam_environment\n")
            f.write("auth      required pam_env.so\n\n")
            f.write("# Use common authentication\n")
            f.write("auth      include common-auth\n\n")
            f.write("# Use common account management\n")
            f.write("account   include common-account\n\n")
            f.write("# Use common password management\n")
            f.write("password  include common-password\n\n")
            f.write("# Use common session management\n")
            f.write("session   include common-session\n\n")
            f.write("# LightDM specific session\n")
            f.write("session optional pam_elogind.so\n")

        # 2. Patch other services (autologin, greeter)
        for pam_service in ["lightdm-autologin", "lightdm-greeter"]:
            pam_file = os.path.join(pam_dir, pam_service)
            if os.path.exists(pam_file):
                print(f"  Patching PAM config: {pam_file}")
                # Allow empty passwords and enable debug
                subprocess.run(f"sed -i -E 's/^(auth|password).*pam_unix.so/& nullok debug/' {pam_file}", shell=True)
                # Remove systemd module (not present/used)
                subprocess.run(f"sed -i '/pam_systemd.so/d' {pam_file}", shell=True)
                # Remove pam_nologin.so (can cause issues if /etc/nologin exists erroneously)
                subprocess.run(f"sed -i '/pam_nologin.so/d' {pam_file}", shell=True)
                # Add elogind module if not present
                subprocess.run(f"grep -q 'pam_elogind.so' {pam_file} || echo 'session optional pam_elogind.so' >> {pam_file}", shell=True)

        # Create persistent directories to be included in the package
        for d in ["var/lib/lightdm", "var/log/lightdm", "var/run/lightdm", "var/lib/lightdm-data", "usr/share/xsessions"]:
            os.makedirs(os.path.join(install_dir, d), exist_ok=True)

        # Create lightdm-session wrapper
        session_wrapper_path = os.path.join(install_dir, "usr/bin/lightdm-session")
        print(f"  Generating session wrapper: {session_wrapper_path}")
        with open(session_wrapper_path, "w") as f:
            f.write("#!/bin/sh\n")
            f.write("# LightDM session wrapper\n\n")
            f.write("# Load profile\n")
            f.write("[ -f /etc/profile ] && . /etc/profile\n")
            f.write("[ -f $HOME/.profile ] && . $HOME/.profile\n\n")
            f.write("# If no session is specified, use xfce as default\n")
            f.write("if [ -z \"$1\" ]; then\n")
            f.write("    exec startxfce4\n")
            f.write("else\n")
            f.write("    case \"$1\" in\n")
            f.write("        xfce|xfce4|startxfce4|default)\n")
            f.write("            exec startxfce4\n")
            f.write("            ;;\n")
            f.write("        *)\n")
            f.write("            if command -v \"$1\" >/dev/null 2>&1; then\n")
            f.write("                exec \"$@\"\n")
            f.write("            else\n")
            f.write("                exec startxfce4\n")
            f.write("            fi\n")
            f.write("            ;;\n")
            f.write("    esac\n")
            f.write("fi\n")
        os.chmod(session_wrapper_path, 0o755)

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
    
    # Create scripts directory and postinst
    scripts_dir = os.path.join(work_dir, "scripts")
    os.makedirs(scripts_dir, exist_ok=True)
    if name == "lightdm":
        postinst_path = os.path.join(scripts_dir, "postinst")
        with open(postinst_path, "w") as f:
            f.write("#!/bin/bash\n")
            f.write("grep -q '^lightdm:' /etc/passwd || { echo \"Creating lightdm user...\"; adduser --system --home /var/lib/lightdm --shell /bin/false --gecos \"LightDM Display Manager\" lightdm; gpkg-worker --pkg lightdm --register-undo \"userdel lightdm\"; }\n")
            f.write("mkdir -p /var/lib/lightdm /var/log/lightdm /var/run/lightdm /var/lib/lightdm-data\n")
            f.write("chown -R lightdm:lightdm /var/lib/lightdm /var/log/lightdm /var/run/lightdm /var/lib/lightdm-data\n")
            f.write("chmod 0750 /var/lib/lightdm /var/log/lightdm\n")
            f.write("chmod 0770 /var/run/lightdm\n")
        os.chmod(postinst_path, 0o755)
    elif name == "linux-pam":
        postinst_path = os.path.join(scripts_dir, "postinst")
        with open(postinst_path, "w") as f:
            f.write("#!/bin/bash\n")
            f.write("echo \"Configuring Linux-PAM...\"\n")
            f.write("# Set SUID for unix_chkpwd - essential for non-root password verification\n")
            f.write("for path in /sbin/unix_chkpwd /usr/sbin/unix_chkpwd /lib/security/unix_chkpwd /lib64/security/unix_chkpwd; do\n")
            f.write("    if [ -f \"$path\" ]; then\n")
            f.write("        echo \"  Setting SUID on $path\"\n")
            f.write("        chmod 4755 \"$path\"\n")
            f.write("    fi\n")
            f.write("done\n")
        os.chmod(postinst_path, 0o755)
    elif name == "polkit":
        postinst_path = os.path.join(scripts_dir, "postinst")
        with open(postinst_path, "w") as f:
            f.write("#!/bin/bash\n")
            f.write("grep -q '^polkitd:' /etc/passwd || { echo \"Creating polkitd user...\"; adduser --system --home /var/lib/polkit-1 --shell /bin/false --gecos \"Polkit Daemon\" polkitd; gpkg-worker --pkg polkit --register-undo \"userdel polkitd\"; }\n")
            # Permissions for polkit (often suid or specific dirs)
            # Polkit rules need to be readable
            f.write("mkdir -p /etc/polkit-1/rules.d\n")
            f.write("mkdir -p /usr/share/polkit-1/rules.d\n")
            f.write("chmod 700 /etc/polkit-1/rules.d\n")
            f.write("chmod 700 /usr/share/polkit-1/rules.d\n")
            f.write("chown polkitd:root /usr/share/polkit-1/rules.d\n")
            f.write("chown polkitd:root /etc/polkit-1/rules.d\n")
            # Set SUID bits
            f.write("chmod 4755 /usr/bin/pkexec\n")
            f.write("chmod 4755 /usr/lib/polkit-1/polkit-agent-helper-1\n")
            # Fix D-Bus Launch Helper (Critical for AccountService spawning)
            f.write("test -f /usr/lib/dbus-1.0/dbus-daemon-launch-helper && chmod 4755 /usr/lib/dbus-1.0/dbus-daemon-launch-helper\n")
            f.write("test -f /usr/lib64/dbus-1.0/dbus-daemon-launch-helper && chmod 4755 /usr/lib64/dbus-1.0/dbus-daemon-launch-helper\n")
            f.write("test -f /usr/libexec/dbus-daemon-launch-helper && chmod 4755 /usr/libexec/dbus-daemon-launch-helper\n")
        os.chmod(postinst_path, 0o755)

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
            if os.path.exists(scripts_dir) and os.listdir(scripts_dir):
                # Add scripts as a directory in final.tar
                for s in os.listdir(scripts_dir):
                    tar.add(os.path.join(scripts_dir, s), arcname=f"scripts/{s}")
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
    update_repo_index()
    print(color("\nLightDM stack built successfully!", Colors.BOLD + Colors.GREEN))

if __name__ == "__main__":
    main()
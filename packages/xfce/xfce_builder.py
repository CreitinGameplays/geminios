#!/usr/bin/env python3
import os
import sys
import subprocess
import shutil
import json
import tarfile
import urllib.request

# Configuration
XFCE_VERSION = "4.18"
BASE_URL = f"https://archive.xfce.org/xfce/{XFCE_VERSION}/src"
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../"))
PACKAGES_DIR = os.path.join(ROOT_DIR, "packages/xfce")
EXPORT_DIR = os.path.join(ROOT_DIR, "export/x86_64/xfce")
LOG_DIR = os.path.join(ROOT_DIR, "logs/xfce")
BUILD_SYSTEM_DIR = os.path.join(ROOT_DIR, "build_system")
TARGET_ENV_SCRIPT = os.path.join(BUILD_SYSTEM_DIR, "target_env.sh")
ENV_CONFIG_SCRIPT = os.path.join(BUILD_SYSTEM_DIR, "env_config.sh")

# Ensure directories exist
os.makedirs(EXPORT_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

# Package Definitions (Order matters!)
PACKAGES = [
    {
        "name": "libxfce4util",
        "version": "4.18.0",
        "desc": "Basic utility library for Xfce4",
        "url": f"{BASE_URL}/libxfce4util-4.18.0.tar.bz2"
    },
    {
        "name": "xfconf",
        "version": "4.18.0",
        "desc": "Flexible configuration storage system",
        "url": f"{BASE_URL}/xfconf-4.18.0.tar.bz2",
        "depends": ["libxfce4util"]
    },
    {
        "name": "libxfce4ui",
        "version": "4.18.0",
        "desc": "Widgets library for Xfce4",
        "url": f"{BASE_URL}/libxfce4ui-4.18.0.tar.bz2",
        "depends": ["libxfce4util", "xfconf"]
    },
    {
        "name": "garcon",
        "version": "4.18.0",
        "desc": "Freedesktop.org compliant menu implementation",
        "url": f"{BASE_URL}/garcon-4.18.0.tar.bz2",
        "depends": ["libxfce4ui"]
    },
    {
        "name": "exo",
        "version": "4.18.0",
        "desc": "Application library for Xfce",
        "url": f"{BASE_URL}/exo-4.18.0.tar.bz2",
        "depends": ["libxfce4ui"]
    },
    {
        "name": "xfwm4",
        "version": "4.18.0",
        "desc": "Window manager for Xfce",
        "url": f"{BASE_URL}/xfwm4-4.18.0.tar.bz2",
        "depends": ["libxfce4ui", "xfconf"]
    },
    {
        "name": "xfce4-panel",
        "version": "4.18.0",
        "desc": "Panel for Xfce",
        "url": f"{BASE_URL}/xfce4-panel-4.18.0.tar.bz2",
        "depends": ["garcon", "exo", "libxfce4ui", "xfconf"]
    },
    {
        "name": "xfdesktop",
        "version": "4.18.0",
        "desc": "Desktop manager for Xfce",
        "url": f"{BASE_URL}/xfdesktop-4.18.0.tar.bz2",
        "depends": ["libxfce4ui", "xfconf"]
    },
    {
        "name": "xfce4-settings",
        "version": "4.18.0",
        "desc": "Settings manager for Xfce",
        "url": f"{BASE_URL}/xfce4-settings-4.18.0.tar.bz2",
        "depends": ["libxfce4ui", "xfconf", "exo"]
    },
    {
        "name": "xfce4-session",
        "version": "4.18.0",
        "desc": "Session manager for Xfce",
        "url": f"{BASE_URL}/xfce4-session-4.18.0.tar.bz2",
        "depends": ["libxfce4ui", "xfconf", "xfce4-panel"]
    },
    {
        "name": "gnu-free-fonts",
        "version": "20120503",
        "desc": "GNU FreeFont (TrueType)",
        "url": "https://ftp.gnu.org/gnu/freefont/freefont-ttf-20120503.zip",
        "type": "font"
    },
    {
        "name": "xfce4",
        "version": "4.18.0",
        "desc": "XFCE4 Desktop Environment (Meta Package)",
        "url": "",
        "type": "meta",
        "depends": [
            "libxfce4util", "xfconf", "libxfce4ui", "garcon", "exo", 
            "xfwm4", "xfce4-panel", "xfdesktop", "xfce4-settings", 
            "xfce4-session", "gnu-free-fonts"
        ]
    }
]

def run_shell(cmd, cwd=None, log_file=None):
    """Run a shell command within the build environment"""
    # Source the environment scripts before running the command
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
    if os.path.exists(dest):
        print(f"  [Cached] {os.path.basename(dest)}")
        return
    print(f"  Downloading {url}...")
    try:
        # User-Agent is sometimes required
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req) as response, open(dest, 'wb') as out_file:
            shutil.copyfileobj(response, out_file)
    except Exception as e:
        print(f"  Error downloading {url}: {e}")
        sys.exit(1)

def build_package(pkg):
    name = pkg["name"]
    version = pkg["version"]
    url = pkg.get("url", "")
    pkg_type = pkg.get("type", "src") # src, font, meta
    
    pkg_full_name = f"{name}-{version}"
    work_dir = os.path.join(PACKAGES_DIR, name)
    src_dir = os.path.join(work_dir, pkg_full_name)
    install_dir = os.path.join(work_dir, "root")
    log_file = os.path.join(LOG_DIR, f"{name}.log")
    
    print(f"=== Building {name} {version} ===")
    
    # 1. Prepare Directory
    os.makedirs(work_dir, exist_ok=True)
    
    # Clean previous build artifacts
    if os.path.exists(install_dir):
        shutil.rmtree(install_dir)
    os.makedirs(install_dir)

    if pkg_type == "meta":
        # Meta package: Just create metadata
        pass
        
    elif pkg_type == "font":
        # Font package: Download, Extract, Copy
        tarball = os.path.join(work_dir, os.path.basename(url))
        download_file(url, tarball)
        
        print("  Extracting...")
        if os.path.exists(src_dir): shutil.rmtree(src_dir)
        
        if tarball.endswith(".zip"):
            subprocess.run(f"unzip -q {tarball} -d {work_dir}", shell=True, check=True)
        else:
            subprocess.run(f"tar -xf {tarball} -C {work_dir}", shell=True, check=True)
        
        print("  Installing...")
        # Move fonts to /usr/share/fonts/TTF
        dest_font_dir = os.path.join(install_dir, "usr/share/fonts/TTF")
        os.makedirs(dest_font_dir, exist_ok=True)
        
        # Copy ttf files
        for root, dirs, files in os.walk(work_dir):
            for file in files:
                if file.lower().endswith(".ttf") or file.lower().endswith(".otf"):
                    shutil.copy2(os.path.join(root, file), dest_font_dir)
                    
        # Also install to ROOTFS for testing/pre-population
        rootfs_font_dir = os.path.join(os.environ.get("ROOTFS", os.path.join(ROOT_DIR, "rootfs")), "usr/share/fonts/TTF")
        os.makedirs(rootfs_font_dir, exist_ok=True)
        subprocess.run(f"cp -r {dest_font_dir}/* {rootfs_font_dir}", shell=True)

    else:
        # Standard Source Package
        # 2. Download & Extract
        tarball = os.path.join(work_dir, os.path.basename(url))
        download_file(url, tarball)
        
        if os.path.exists(src_dir):
            shutil.rmtree(src_dir)
        
        print("  Extracting...")
        # Using tar command because python tarfile can be slow or fussy with some formats
        subprocess.run(f"tar -xf {tarball} -C {work_dir}", shell=True)
        
        # 3. Configure & Compile
        print("  Configuring...")

        # Staging Directory for XFCE dependencies (to keep rootfs clean)
        staging_dir = os.path.join(PACKAGES_DIR, "staging")
        os.makedirs(staging_dir, exist_ok=True)
        
        # Update Environment to look in Staging
        # We prepend staging paths so they take precedence
        env_vars = (
            f"export PKG_CONFIG_PATH={staging_dir}/usr/lib/pkgconfig:{staging_dir}/usr/share/pkgconfig:$PKG_CONFIG_PATH && "
            f"export CFLAGS=\"-I{staging_dir}/usr/include $CFLAGS\" && "
            f"export LDFLAGS=\"-L{staging_dir}/usr/lib $LDFLAGS\" && "
            f"export XDG_DATA_DIRS={staging_dir}/usr/share:$XDG_DATA_DIRS"
        )
        
        # Standard configure flags for GeminiOS
        # We install to /usr in the package context
        wrapper_path = os.path.join(BUILD_SYSTEM_DIR, "wrap_bin/gdbus-codegen")
        configure_cmd = (
            f"{env_vars} && GDBUS_CODEGEN={wrapper_path} ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static --disable-introspection"
        )
        
        if run_shell(configure_cmd, cwd=src_dir, log_file=log_file) != 0:
            print(f"  [ERROR] Configure failed. Check {log_file}")
            return False
            
        # Hack for xfconf: Prevent regeneration by modifying Makefile
        if name == "xfconf":
            print("  [Hack] Patching Makefile to prevent gdbus-codegen regeneration...")
            makefile_path = os.path.join(src_dir, 'common/Makefile')
            with open(makefile_path, 'r') as f:
                content = f.read()
            
            # Remove dependencies for the bindings
            # We replace the dependency line with an empty target or just remove the dependency on Makefile
            content = content.replace('xfconf-gdbus-bindings.c: xfconf-dbus.xml Makefile', 'xfconf-gdbus-bindings.c:')
            content = content.replace('xfconf-gdbus-bindings.h: xfconf-dbus.xml Makefile', 'xfconf-gdbus-bindings.h:')
            
            with open(makefile_path, 'w') as f:
                f.write(content)
                
            # Also touch the files to be sure
            subprocess.run(f"touch {os.path.join(src_dir, 'common/xfconf-gdbus-bindings.c')}", shell=True)
            subprocess.run(f"touch {os.path.join(src_dir, 'common/xfconf-gdbus-bindings.h')}", shell=True)
            
        print("  Compiling...")
        if run_shell(f"{env_vars} && make -j$(nproc)", cwd=src_dir, log_file=log_file) != 0:
            print(f"  [ERROR] Make failed. Check {log_file}")
            return False
            
        print("  Installing to staging...")
        if run_shell(f"make DESTDIR={install_dir} install", cwd=src_dir, log_file=log_file) != 0:
            print(f"  [ERROR] Make install failed. Check {log_file}")
            return False

        print("  Installing to BUILD STAGING (for dependencies)...")
        # Install to our local staging dir instead of ROOTFS
        if run_shell(f"make DESTDIR={staging_dir} install", cwd=src_dir, log_file=log_file) != 0:
            print(f"  [ERROR] Make install to STAGING failed. Check {log_file}")
            return False
            
        # Remove .la files from staging
        subprocess.run(f"find {staging_dir} -name '*.la' -delete", shell=True)        

    # 4. Create Control File
    print("  Creating control.json...")
    control_data = {
        "package": name,
        "version": version,
        "architecture": "x86_64",
        "maintainer": "GeminiOS User",
        "description": pkg["desc"],
        "depends": pkg.get("depends", [])
    }
    with open(os.path.join(work_dir, "control.json"), "w") as f:
        json.dump(control_data, f, indent=2)
        
    # 5. Pack .gpkg (GPKG v2 Format)
    print("  Packaging (GPKG v2)...")
    gpkg_name = f"{name}_{version}_x86_64.gpkg"
    gpkg_path = os.path.join(EXPORT_DIR, gpkg_name)
    
    # Structure:
    # package.gpkg (zstd)
    #   -> final.tar
    #        -> control.json
    #        -> data.tar.zst
    #             -> (contents of root/)
    
    import tempfile
    
    with tempfile.TemporaryDirectory() as tmp_dir:
        # A. Create data.tar from root/
        data_tar = os.path.join(tmp_dir, "data.tar")
        # We want the contents of install_dir (root/) to be at the root of the archive (or under data/ prefix if supported)
        # gpkg_worker supports data/ prefix or raw. Let's use raw for simplicity or match SDK.
        # SDK uses: tar -cf data.tar -C root_dir .
        subprocess.run(f"tar -cf {data_tar} -C {install_dir} .", shell=True, check=True)
        
        # B. Compress data.tar -> data.tar.zst
        data_tar_zst = os.path.join(tmp_dir, "data.tar.zst")
        subprocess.run(f"zstd -q -f {data_tar} -o {data_tar_zst}", shell=True, check=True)
        
        # C. Create final.tar containing control.json and data.tar.zst
        final_tar = os.path.join(tmp_dir, "final.tar")
        with tarfile.open(final_tar, "w") as tar:
            tar.add(os.path.join(work_dir, "control.json"), arcname="control.json")
            tar.add(data_tar_zst, arcname="data.tar.zst")
            
        # D. Compress final.tar -> package.gpkg
        subprocess.run(f"zstd -q -f {final_tar} -o {gpkg_path}", shell=True, check=True)

    print(f"  [DONE] Created {gpkg_path}")
    return True

def setup_wrappers():
    """Generates necessary wrappers for the build process"""
    wrapper_path = os.path.join(BUILD_SYSTEM_DIR, "wrap_bin/gdbus-codegen")
    if not os.path.exists(os.path.dirname(wrapper_path)):
        os.makedirs(os.path.dirname(wrapper_path), exist_ok=True)
        
    print(f"Generating wrapper: {wrapper_path}")
    with open(wrapper_path, "w") as f:
        f.write('#!/bin/bash\n')
        f.write('# Wrapper to force gdbus-codegen to target an older GLib version AND patch the output\n')
        f.write('ARGS=("$@")\n')
        f.write('# 1. Run the original codegen\n')
        f.write('/usr/bin/gdbus-codegen "${ARGS[@]}" --glib-min-required 2.78 --glib-max-allowed 2.78\n')
        f.write('RET=$?\n')
        f.write('if [ $RET -ne 0 ]; then exit $RET; fi\n')
        f.write('\n')
        f.write('# 2. Find the output file argument\n')
        f.write('PREFIX=""\n')
        f.write('for ((i=0; i<${#ARGS[@]}; i++)); do\n')
        f.write('  if [[ "${ARGS[i]}" == "--generate-c-code" ]]; then\n')
        f.write('    PREFIX="${ARGS[i+1]}"\n')
        f.write('    break\n')
        f.write('  fi\n')
        f.write('done\n')
        f.write('\n')
        f.write('# 3. Patch the file if found\n')
        f.write('if [ -n "$PREFIX" ] && [ -f "${PREFIX}.c" ]; then\n')
        f.write('    # Replace g_variant_builder_init_static with g_variant_builder_init\n')
        f.write('    sed -i "s/g_variant_builder_init_static/g_variant_builder_init/g" "${PREFIX}.c"\n')
        f.write('fi\n')
        f.write('exit 0\n')

    os.chmod(wrapper_path, 0o755)

def update_repo_index():
    """Updates the Packages.json.zst index in the export directory"""
    print("\n=== Updating Repository Index ===")
    scanrepo_script = "/home/creitin/Documents/geminios-sdk/gpkg_scanrepo.py"
    # The repo root is one level above EXPORT_DIR/xfce
    repo_root = os.path.abspath(os.path.join(EXPORT_DIR, ".."))
    
    if os.path.exists(scanrepo_script):
        subprocess.run([sys.executable, scanrepo_script, repo_root], check=True)
    else:
        print(f"Warning: {scanrepo_script} not found. Index not updated.")

def main():
    print(f"Starting XFCE Build for {XFCE_VERSION}")
    print(f"Export Directory: {EXPORT_DIR}")
    
    setup_wrappers()
    
    for pkg in PACKAGES:
        if not build_package(pkg):
            sys.exit(1)
            
    update_repo_index()
    print("\nAll packages built and indexed successfully!")

if __name__ == "__main__":
    main()

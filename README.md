![GeminiOS Screenshot](screenshot/img0.png)

# GeminiOS Documentation

GeminiOS is a minimal, open-source, educational Linux-based Operating System built from scratch (made by Google Gemini 3). It does not rely on existing distributions (like Debian or Arch) or build systems (like Buildroot).

Started with Google Gemini 3 Pro, let's see how far we can go with that.

## Setup and Build

To build GeminiOS, you need a Linux host (Ubuntu/Debian recommended) with the following dependencies:

*Only tested on a Debian 13 Trixie x86_64 system*

```bash
sudo apt install build-essential bison flex libncurses-dev libssl-dev libelf-dev \
                 zlib1g-dev libzstd-dev xorriso qemu-system-x86 git bc wget patch \
                 python3 python3-mako python3-markupsafe mtools grub-pc-bin lz4 \
                 gperf libxcb-keysyms1-dev meson ninja-build squashfs-tools cpio \
                 libxml2-dev libxslt1-dev texinfo intltool valac
```

Make sure to make the build scripts executable:
```bash
chmod +x ports/**/build.sh
chmod +x build_system/*.sh
```

### Python Environment (Required)

The build system, particularly the Python package build, requires a specific host Python version (3.11) to avoid cross-compilation version mismatches (e.g., building Python 3.11 using a host Python 3.13). We use **pyenv** to ensure the correct version is available.

1.  **Install Prerequisites for Python Build**:
    ```bash
    sudo apt install libreadline-dev libsqlite3-dev libbz2-dev libncurses5-dev libgdbm-dev libnss3-dev libssl-dev libffi-dev liblzma-dev
    ```

2.  **Install pyenv**:
    If you don't have pyenv, install it (or use your distro's package manager):
    ```bash
    curl https://pyenv.run | bash
    # Remember to add the init lines to your shell config (~/.bashrc) as instructed by the installer!
    source ~/.bashrc
    ```

3.  **Install Python 3.11.9**:
    ```bash
    pyenv install 3.11.9
    ```
    *The build scripts are hardcoded to look for `~/.pyenv/versions/3.11.9/bin/python3.11` for critical build steps.*

**Note**: Host Python version > 3.12 may fail due to the removal of the `pipes` and `distutils` modules in some external dependencies (e.g., older GLib/Meson versions). If you encounter issues, consider using a compatibility layer or patching the affected files, though the `builder.py` and `pyenv` should handle this automatically.

### The Shim Wrapper (`build_system/shim_wrapper.c`)
This is the core component that enforces the cross-compilation environment. 
- **What it is**: A small C program compiled into `build_system/shim_wrapper`.
- **How it works**: We create symlinks for standard tools (gcc, g++, ar, etc.) in `build_system/shim/` that all point to this wrapper binary.
- **Runtime Behavior**: When a build script calls `gcc`, it actually calls our wrapper. The wrapper:
  1.  **Sanitizes the Environment**: Unsets `LD_LIBRARY_PATH`, `PYTHONPATH`, etc., to prevent host contamination.
  2.  **Injects Flags**: Automatically adds `--sysroot=/path/to/geminios/rootfs` to compiler arguments.
  3.  **Redirects**: Calls the path to the real cross-compiler or system tool with the modified arguments.

To recompile the wrapper if you modify `shim_wrapper.c`:
```bash
make -C build_system
```

This ensures that every package build automagically targets GeminiOS without requiring every single makefile to be perfectly configured for cross-compilation.

1.  **Run Builder**:
    ```bash
    python3 builder.py
    ```
- If you want to force a rebuild of every package, use the `--force` flag:
    ```bash
    python3 builder.py --force
    ```

- Or if you want to build a specific package, just run:
    ```bash
    python3 builder.py <package_name>
    ```

- You can also force a rebuild of a specific package by using the `--force` flag:
    ```bash
    python3 builder.py <package_name> --force
    ```
- To clean the entire build environment, use the `--clean` flag:
    ```bash
    python3 builder.py --clean
    ```

## Development Workflow

- **The Kernel**: The kernel must be compiled before running the main builder.
  See the [Kernel Compilation](#kernel-compilation) section below.

- **Core System (Ginit)**: The initialization system and core utilities reside in the `ginit/` directory. It is built as part of the `geminios_core` port but can be developed independently using its own `Makefile`.

- **Userspace Packages**: Most other system utilities are in `packages/` (system utilities).

- **Verification**: The build system now uses a manifest-based verification system (`build_system/package_manifests.json`). If a package build fails or artifacts are missing, the builder will report exactly what is missing.

## Ginit (Init System)

Ginit is modularized for easier development. It provides `init`, `login`, and `getty`.
To build it manually:
```bash
cd ginit && make
```
For more information, see [ginit/README.md](https://github.com/CreitinGameplays/ginit/blob/master/README.md).

## Build System Architecture

GeminiOS uses a custom "Shim Wrapper" architecture to ensure build isolation and correct cross-compilation without needing a complex chroot setup during the build phase.

## Kernel Compilation

Run these commands once to prepare the kernel:
```sh
mkdir -p external_dependencies
cd external_dependencies
# Download kernel
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.14.tar.xz
tar -xf linux-6.6.14.tar.xz
rm linux-6.6.14.tar.xz
cd linux-6.6.14

# 3. Configure and Compile
make x86_64_defconfig

# 1. Enable Framebuffer and QEMU Drivers
./scripts/config --enable CONFIG_FB
./scripts/config --enable CONFIG_FB_VESA
./scripts/config --enable CONFIG_FB_EFI
./scripts/config --enable CONFIG_DRM
./scripts/config --enable CONFIG_DRM_BOCHS
./scripts/config --enable CONFIG_DRM_VIRTIO_GPU
./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
./scripts/config --enable CONFIG_DRM_FBDEV_EMULATION
./scripts/config --set-val CONFIG_DRM_FBDEV_OVERALLOC 100
./scripts/config --enable CONFIG_INPUT_EVDEV

# 2. Enable SquashFS, OverlayFS and ISO9660 (Required for GeminiOS Live ISO)
./scripts/config --enable CONFIG_SQUASHFS
./scripts/config --enable CONFIG_SQUASHFS_ZSTD
./scripts/config --enable CONFIG_SQUASHFS_XZ
./scripts/config --enable CONFIG_OVERLAY_FS
./scripts/config --enable CONFIG_BLK_DEV_LOOP
./scripts/config --enable CONFIG_ISO9660_FS
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
./scripts/config --enable CONFIG_TMPFS
./scripts/config --enable CONFIG_MSDOS_PARTITION
./scripts/config --enable CONFIG_EFI_PARTITION

# 3. Finalize and Compile
make olddefconfig
make -j$(nproc) bzImage
```

---

### Patch System

GeminiOS uses a centralized patch system. Manual fixes for external dependencies are stored as `.patch` files in the `patches/` directory and are automatically applied by the respective build scripts in `ports/`.

Current patches included:
- `libffi-3.4.4.patch`: Fixes trampoline execution for Linux/Cygwin.
- `gobject-introspection-1.78.1-msvc.patch`: Fixes `MSVCCompiler` import issues.
- `libXrender-0.9.11-glyph.patch`: Fixes glyph allocation in XRender.
- `xorg-server-1.20.14-glxdri2.patch`: Fixes `bool` type conflict in GLX DRI2.

---


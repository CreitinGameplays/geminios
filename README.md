# GeminiOS Documentation

GeminiOS is a minimal, open-source, educational Linux-based Operating System built from scratch (fully made by Google Gemini 3). It does not rely on existing distributions (like Debian or Arch) or build systems (like Buildroot).

Started with Google Gemini 3 Pro, let's see how far we can go with that.

## Prerequisites

You need a Linux host (Ubuntu/Debian recommended) with the following tools:

```bash
sudo apt install build-essential bison flex libncurses-dev libssl-dev libelf-dev zlib1g-dev libzstd-dev xorriso qemu-system-x86 git bc python3 python-is-python3 mtools grub-pc-bin lz4 gperf libxcb-xkb-dev meson ninja-build
```

Update the filepaths of `native.ini` file.

## Development Workflow

- You MUST build the kernel first!
Run the following commands in order:
```sh
cd ~/geminios
mkdir external_dependecies
cd external_dependecies
# Download kernel (adjust version if link rots)
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.14.tar.xz
tar -xf linux-6.6.14.tar.xz
cd linux-6.6.14

# 1. Enable Framebuffer and QEMU Drivers (Built-in, not modules)
./scripts/config --enable CONFIG_FB
./scripts/config --enable CONFIG_FB_VESA
./scripts/config --enable CONFIG_FB_EFI
./scripts/config --enable CONFIG_DRM
./scripts/config --enable CONFIG_DRM_BOCHS
./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
# Enable legacy /dev/fb0 support for DRM drivers
./scripts/config --enable CONFIG_DRM_FBDEV_EMULATION

# 2. Enable Input Event Interface (for Mouse/Keyboard)
./scripts/config --enable CONFIG_INPUT_EVDEV

# 3. AUTOMATICALLY resolve all dependencies and new questions
make olddefconfig

# Clean environment
make mrproper

# Generate a default x86_64 configuration
make x86_64_defconfig

# Compile (this takes time!)
# -j$(nproc) uses all CPU cores
make -j$(nproc) bzImage
```

- Step A: The Userspace Code (`src/...` and `packages/...`)
This is where you will spend most of your time.

- Step B: The Build Script (`build.sh`)
Use this script to compile your C++ code, package the filesystem, and generate the ISO.

Make it executable:
```bash
chmod +x build.sh
```

Build! (this gonna take a very while the first time, just sit, wait and pray you won't get any errors)
```bash
./build.sh
```

- Save source into a txt file if you want to send it to AI Studio:
```python
python save_src.py --root . --exclude packages/system/desktop/stb_image.h --extra-excludes external_dependencies* glibc* grub* rootfs*
```

Note: mkfs only supports ext2 for now.

Manual fixes done in source code of external dependencies:
`external_dependencies/libffi-3.4.4/src/tramp.c`
```diff
│ 60 + #if defined (__linux__) || defined (__CYGWIN__)
│ 61 + extern int open_temp_exec_file (void);
│ 62 + #endif
```

`external_dependencies/glib-2.78.3/gio/gdbus-2.0/codegen/utils.py`
```diff
│ 200 - return (distutils.version.LooseVersion(v), key[1])
│ 200 + return (LooseVersion(v), key[1])
```

`glibc-build/Makefile`
```diff
| 1 - srcdir = ../glibc-2.39 
│ 1 + srcdir = ../external_dependencies/glibc-2.39
```
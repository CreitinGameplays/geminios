# GeminiOS Documentation

GeminiOS is a minimal, open-source, educational Linux-based Operating System built from scratch (fully made by Google Gemini 3). It does not rely on existing distributions (like Debian or Arch) or build systems (like Buildroot). This project follows the Linux From Scratch (LFS) philosophy.

Started with Google Gemini 3 Pro, let's see how far we can go with that.

## Prerequisites

You need a Linux host (Ubuntu/Debian recommended) with the following tools:

```bash
sudo apt update
sudo apt install build-essential bison flex libncurses-dev libssl-dev libelf-dev zlib1g-dev libzstd-dev xorriso qemu-system-x86 git bc
```

## Development Workflow

- You MUST build the kernel first!

```sh
cd ~/geminios
# Download kernel (adjust version if link rots)
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.14.tar.xz
tar -xf linux-6.6.14.tar.xz
cd linux-6.6.14

# 1. Enable Framebuffer and QEMU Drivers (Built-in, not modules)
./scripts/config --enable CONFIG_FB
./scripts/config --enable CONFIG_FB_VESA
./scripts/config --enable CONFIG_DRM
./scripts/config --enable CONFIG_DRM_BOCHS
./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
# Enable legacy /dev/fb0 support for DRM drivers (Required for Desktop)
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

Build!
```bash
./build.sh
```

# Save source into a txt file:
```python
python save_src.py --root . --exclude packages/system/desktop/stb_image.h --extra-excludes linux* bash* nano* grep* ncurses* sed* gawk* grub* kbd* rootfs* lvgl* lv_drivers* project_export.txt 
```

Note: mkfs only supports ext2 for now.

Note for Gemini: HEY TRY TO MAKE THIS SOURCE CODE FILES AND DIRECTORIES ORGANIZED PLS THANKS
ALSO ADD A LOT OF DEBUG IN CODES BECAUSE IT GONNA BE VERY USEFUL

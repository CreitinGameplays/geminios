# Checklist: Implementing OpenGL/Mesa Support in GeminIOS

This document outlines the steps required to transition GeminIOS from a basic framebuffer-only display to a hardware-accelerated (or high-performance software) OpenGL rendering stack.

---

## Phase 0: Host Environment Preparation
Mesa's build system (Meson) requires specific Python modules for code generation.
- [x] Ensure `Mako` is installed on the host: `pip install Mako` (Verified)
- [x] Ensure `pyyaml` is installed on the host: `pip install pyyaml` (Verified)

---

## Phase 1: The Foundation (libdrm & Core Deps)
Before Mesa, you need the userspace library for the Direct Rendering Manager and core compression/elf libraries.
- [x] **Zstd:** Added to `build.sh` (Required for shader cache).
- [x] **Libelf:** Added to `build.sh` (via `elfutils`).
- [x] **libdrm:** Added to `build.sh`.
- [x] **Configuration:** Configured with `vmwgfx` enabled and others disabled for simplicity.
- [x] **Install:** Deployment to `rootfs` added to `build.sh`.

---

## Phase 2: Performance (LLVM) - *Optional but Recommended*
...
---

## Phase 3: The Graphics Stack (Mesa)
This is the core implementation of OpenGL, EGL, and GLES. Requires several X11/XCB utility libraries.
- [x] **xcb-util:** Added to `build.sh`.
- [x] **xcb-util-keysyms:** Added to `build.sh`.
- [x] **libXxf86vm:** Added to `build.sh`.
- [x] **Download:** Added to `build.sh`.
- [x] **Driver Selection:** Initialized with `swrast`.

---

## Phase 4: Modernizing the Dispatch (libglvnd)
Standardizes how apps find GL drivers.
- [x] **Download:** `https://gitlab.freedesktop.org/glvnd/libglvnd`
- [x] **Action:** Build and install to `rootfs` to provide the primary `libGL.so` entry points.

---

## Phase 5: Rebuilding Xorg with GLX
Now that Mesa provides the DRI (Direct Rendering Infrastructure) headers.
- [x] **Modify `build.sh`:** Updated `xorg-server` configuration.
- [x] **Re-enable features:** GLX, DRI, DRI2, DRI3, Glamor, and libdrm enabled.

---

## Phase 6: Finalizing UI Support
Revert the workarounds created for the minimal build.
- [x] **libepoxy:** Removed `-Degl=no -Dglx=no` from Meson options.
- [x] **GTK+ 3:** Clean and rebuild. It will now detect OpenGL support and enable hardware acceleration for UI elements (Will happen on next full build).

---

## Phase 7: Verification
Once the OS is booted, run these tests:
- [x] **Check DRI Device:** `ls -l /dev/dri/card0` (should exist if kernel modules `virtio-gpu` or `i915` are loaded).

---

Run the VM with virtio GPU:

Test the virtio GPU:

```
qemu-system-x86_64 -m 2G -cdrom GeminiOS.iso -device virtio-vga-gl -display sdl,gl=on -cpu host -smp 2 -enable-kvm -hda disk.qcow2 -boot d -serial stdio
```

```
qemu-system-x86_64 -m 4G -device virtio-vga-gl -display sdl,gl=on -cpu host -smp 2 -enable-kvm -hda disk.qcow2 -boot d -nic user,model=e1000,id=net0 -serial stdio
```
# Ginit Decoupling & Modularization Plan

## Objective
Extract the GeminiOS Core (`ginit`, `login`, `getty`, and shared libraries) into a standalone directory structure that can be easily converted into a Git Submodule (`ginit`). This improves modularity, simplifies the main OS repository, and allows for independent development and testing of the init system.

## Phase 1: Repository Structure & Migration
- [ ] Create the new directory structure:
  - `ginit/src/` (Source code)
  - `ginit/services/` (Default .gservice files)
  - `ginit/tests/` (Unit tests)
  - `ginit/include/` (Public headers, if any)
- [ ] Move source files from `src/` to `ginit/src/`:
  - [ ] `ginit.cpp`
  - [ ] `gservice_manager.cpp/hpp`
  - [ ] `gservice_parser.cpp/hpp`
  - [ ] `login.cpp`
  - [ ] `getty.cpp`
  - [ ] `network.cpp/h`
  - [ ] `signals.cpp/h`
  - [ ] `user_mgmt.cpp/h`
  - [ ] `sys_info.h`
  - [ ] `debug.h`
- [ ] Move services from `ports/geminios_core/services/` to `ginit/services/`.
- [ ] Move tests from `tests/` to `ginit/tests/`.

## Phase 2: Build System (Makefile)
- [ ] Create a comprehensive `Makefile` in `ginit/`:
  - [ ] Compile shared utilities into a static library `libgemcore.a` (contains `network`, `signals`, `user_mgmt`).
  - [ ] Compile `ginit` (PID 1).
  
  - [ ] Compile `login` (Login Manager).
  - [ ] Compile `getty` (TTY Manager).
  - [ ] Implement `make install` with `DESTDIR` support for easy integration with `rootfs`.
- [ ] Add unit test targets to the `Makefile`.

## Phase 3: Integration & Dependency Fixes
- [ ] Update `ports/geminios_core/build.sh`:
  - Replace manual `g++` calls with `cd ginit && make install DESTDIR=$ROOTFS`.
- [ ] Update `ports/geminios_complex/build.sh`:
  - Update `-I` include paths to point to `ginit/src/`.
  - Link `gpkg`, `ping`, `installer`, etc., against `ginit/src/libgemcore.a`.
- [ ] Update `ports/geminios_pkgs/build.sh`:
  - Update `-I` include paths to point to `ginit/src/`.
- [ ] Update `builder.py`:
  - Ensure `verify_rootfs_integrity` still looks for the correct paths.
  - Check if any hardcoded logic depends on the old `src/` directory.

## Phase 4: Verification & Testing
- [ ] Run `ginit` unit tests.
- [ ] Perform a full OS build using `builder.py`.
- [ ] Verify `rootfs` integrity:
  - Check `/bin/init`, `/bin/login`, `/sbin/getty`.
  - Check `/etc/ginit/services/system/dbus.gservice`.
- [ ] Boot in QEMU and verify:
  - Init system starts correctly.
  - Services (like D-Bus) are launched.
  - Login prompt appears and functions.
  - Shell is usable.

## Phase 5: Git Submodule Conversion
- [ ] Initialize Git in `ginit/`.
- [ ] (Optional) Push to a remote repository.
- [ ] Add `ginit` as a submodule to the main `geminios` repository.
- [ ] Remove the old `src/` directory from the main repository.

# GNOME Shell + Full Wayland Support Roadmap

Goal: make GeminiOS capable of running a full modern GNOME Shell session on Wayland natively, before packaging GNOME itself as `.gpkg`.

This is not a package-conversion checklist. It is an OS/runtime checklist. The repacker already proved that large desktop userlands can be imported. The remaining work is making GeminiOS provide the session, graphics, policy, and media plumbing those packages expect.

## Current Baseline

Already present:
- Wayland protocol/runtime foundation
- Wayland-enabled `libxkbcommon`
- Wayland-enabled GTK 3
- Mesa with `x11` and `wayland` platforms
- X11 desktop flow working with XFCE
- D-Bus system bus
- manual Wayland session bootstrap with XDG session/runtime exports
- session environment drop-in support plus `wayland-session-report` diagnostics
- `gpkg` importing large Debian desktop packages successfully

Still missing at the OS level:
- native Wayland compositor/session flow
- complete seat/session management polish
- XDG desktop portal stack
- modern audio/screen-share stack
- GNOME session daemons and policy integration
- GNOME Shell compositor stack (`mutter`, `gnome-shell`, `gjs`, etc.)

## Architecture Decision

Before implementation, lock this in:

- [ ] Keep `ginit` as PID 1.
- [ ] Do not depend on `systemd` as init.
- [ ] Provide the session APIs modern desktops expect through a compatibility layer:
  - preferred path: `elogind`
  - fallback path for wlroots-only sessions: `seatd`
- [ ] Support both:
  - X11 session fallback
  - native Wayland session as the long-term default

Recommendation:
- Use `elogind` for GNOME/Mutter compatibility.
- Optionally add `seatd` later for wlroots compositors if needed.

## Phase 1: Session and Seat Management

Modern Wayland desktops depend on proper login/session ownership, device access, and runtime directories.

- [x] Add `pam`-backed session creation that reliably sets:
  - `XDG_RUNTIME_DIR`
  - `XDG_SESSION_TYPE`
  - `XDG_CURRENT_DESKTOP`
  - `XDG_SESSION_DESKTOP`
  - `DBUS_SESSION_BUS_ADDRESS`
- [x] Add `elogind` as the primary `logind` provider.
- [x] Start and supervise `elogind` from `ginit`.
- [ ] Ensure `polkit` can query active sessions through `elogind`.
- [x] Ensure `/run/user/<uid>` is created with correct ownership and lifetime.
- [x] Add support for user sessions in `ginit` or a compatible session bootstrap layer.
- [ ] Verify DRM/input device permissions are granted to the active graphical session.

Definition of done:
- `loginctl`-style session information is available.
- a logged-in user owns `/run/user/<uid>`.
- a compositor can open DRM and input devices without running as root.

## Phase 2: Core Wayland Desktop Runtime

This is the shared base needed by GNOME and most modern Wayland desktops.

- [x] Add `libinput`.
- [ ] Add `libseat` support if required by specific compositors/components.
- [ ] Add `xkbcommon` tooling/runtime validation.
- [x] Add `Xwayland` so legacy X11 applications work inside Wayland sessions.
- [ ] Add `xdg-desktop-portal`.
- [ ] Add at least these portal backends:
  - `xdg-desktop-portal-gtk`
  - GNOME backend later with GNOME session stack
- [x] Add `dconf`.
- [ ] Add `gvfs`.
- [ ] Add `glib-networking`.
- [ ] Add `libsecret`.
- [ ] Add `gnome-keyring`.
- [ ] Add `colord`.
- [ ] Add `geoclue` if GNOME Settings features require it.
- [ ] Add `accountsservice` if GNOME control-center/session pieces require it.
- [ ] Add `upower`.
- [ ] Add `rtkit`.
- [ ] Add `pipewire`.
- [ ] Add `wireplumber`.
- [ ] Add `pipewire-pulse`.
- [x] Add `xdg-user-dirs` and initial user dir population.
- [x] Ensure `gsettings` schema compilation happens automatically after installs.

Definition of done:
- portals work
- secret storage works
- media/audio stack works
- X11 apps can run under Wayland via `Xwayland`

## Phase 3: Graphics and Compositor Validation

Before GNOME Shell, validate the graphics/session model with a simpler native Wayland compositor.

- [ ] Add one small validation compositor first:
  - preferred: `weston`
  - optional: `cage`
- [ ] Verify:
  - DRM/KMS modesetting
  - input devices
  - cursor rendering
  - `Xwayland`
  - portal interactions
  - PipeWire/portal-based screen capture path
- [ ] Only after this is stable, move to `mutter`.

Reason:
- this isolates generic Wayland/runtime failures from GNOME-specific failures.

Definition of done:
- GeminiOS can boot into a native Wayland session with a minimal compositor and launch GTK apps plus X11 apps through `Xwayland`.

## Phase 4: GNOME Foundation Stack

GNOME Shell requires significantly more than GTK apps.

- [ ] Add `graphene`.
- [ ] Add `cogl` if required by selected `mutter` version.
- [ ] Add the exact `mutter` dependency stack used by the target GNOME release.
- [ ] Add `mozjs` / SpiderMonkey version required by `gjs`.
- [ ] Add `gjs`.
- [ ] Add `mutter`.
- [ ] Add `gnome-shell`.
- [ ] Add `gnome-session`.
- [ ] Add `gnome-settings-daemon`.
- [ ] Add `gnome-control-center`.
- [ ] Add `nautilus`.
- [ ] Add `gnome-shell-extensions` support only after base shell is stable.
- [ ] Add `adwaita` runtime/theme stack aligned with the GNOME version in use.

Important:
- Target one GNOME release train and keep the core versions aligned.
- Do not mix random Debian package generations for `mutter`, `gnome-shell`, `gjs`, and `mozjs`.

Definition of done:
- `gnome-shell --wayland` starts successfully inside a user session.
- `gnome-session` starts the expected core daemons.

## Phase 5: Authentication and Display Entry

Do not make GDM the first milestone.

Recommended order:
- [ ] First support launching GNOME Wayland from a manual session bootstrap.
- [ ] Then add a graphical login manager.
- [ ] Evaluate `gdm` only after the manual session is stable.

Why:
- GDM adds another large layer of session, PAM, greeter, and user-switching complexity.
- It is much easier to debug GNOME Shell first, then the display manager.

Definition of done:
- manual GNOME Wayland session works first
- graphical login flow is added second

## Phase 6: Package Manager and Repository Integration

Only after the above runtime stack is working:

- [ ] Add the GNOME runtime/system packages to `gpkg_system_provides.txt` only when GeminiOS actually ships them.
- [ ] Add publisher overrides for GNOME-specific virtual/system dependencies.
- [ ] Publish GNOME packages in a staged order:
  - core libraries
  - session daemons
  - shell/compositor
  - control center and apps
- [ ] Avoid importing GDM until the runtime stack is proven.

## Phase 7: Verification Matrix

Minimum required test matrix:

- [ ] `weston` or another minimal compositor starts on real GeminiOS Wayland
- [ ] GTK3 Wayland app runs
- [ ] `Xwayland` app runs
- [ ] portals respond
- [ ] PipeWire audio works
- [ ] PipeWire screen-share path works
- [ ] `polkit` authorization prompt works
- [ ] `gnome-shell --wayland` starts
- [ ] `gnome-session` starts
- [ ] GNOME Settings opens
- [ ] Nautilus opens
- [ ] Firefox runs under GNOME Wayland
- [ ] logout/login cycle works without leaving stale session state

## Suggested Implementation Order

If the goal is fastest route to a real GNOME Wayland desktop:

1. [x] `elogind`
2. [x] `libinput`
3. [x] `Xwayland`
4. [ ] `dconf`, `gvfs`, `glib-networking`, `libsecret`, `gnome-keyring`
5. [ ] `xdg-desktop-portal` + GTK backend
6. [ ] `pipewire` + `wireplumber` + `rtkit`
7. [ ] `weston` for native Wayland validation
8. [ ] `graphene`, `mozjs`, `gjs`, `mutter`
9. [ ] `gnome-shell`, `gnome-session`, `gnome-settings-daemon`
10. [ ] GNOME applications
11. [ ] optional `gdm`

## What Not To Do

- [ ] Do not try to publish the full GNOME metapackage first and debug later.
- [ ] Do not add `libsystemd0`-style libraries to system-provides unless GeminiOS really ships compatible implementations.
- [ ] Do not rely on wrapper scripts as the main fix for compositor/session gaps.
- [ ] Do not mix arbitrary GNOME component versions.

## Immediate Next Milestone

The next milestone should be:

- [ ] validate the new manual session bootstrap with a real compositor package on GeminiOS, confirming DRM/input access, runtime dir ownership, and `Xwayland`
- [ ] use `wayland-session-report` from a TTY before launching the first validation compositor to confirm the session environment and device visibility

Once that is stable, GNOME Shell becomes a realistic target instead of a package-conversion experiment.

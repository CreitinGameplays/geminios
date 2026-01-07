# change lvgl to xfce desktop
# ALWAYS UPDATE THIS LIST

# PHASE 1: SYSTEM FOUNDATION (Migration from Static to Dynamic)
# Current Status: Everything is -static. XFCE requires Shared Objects (.so).
- [x] Implement Shared Library Support:
    - [x] Rebuild Glibc or Musl with dynamic loading enabled.
    - [x] Install the dynamic linker to /lib/ld-linux-x86-64.so.2.
    - [x] Update build.sh to remove -static for GUI-related builds.
- [x] Compile Base Utilities:
    - [x] Pkg-config: Required for all subsequent builds to find library paths.
    - [x] Python3: Required by many XFCE/GTK build scripts (Meson/Ninja).
    - [x] Perl: Required for Xorg header generation.

# PHASE 2: CORE GRAPHICS INFRASTRUCTURE (X11)
# Current Status: System uses /dev/fb0 directly via LVGL.
- [x] Build Xorg-Server Foundation:
    - [x] xorgproto: Standard X11 protocol headers.
    - [x] util-macros: Helper macros for X build system.
    - [x] xtrans: Network-independent transport layer.
    - [x] libXau & libXdmcp: Authentication libraries.
    - [x] xcb-proto & libxcb: The C-language Binding for X.
    - [x] libX11: The primary X library.
    - [x] libXext: Common X extensions.
- [x] Build Xorg-Server:
    - [x] xorg-server binary.
    - [x] libdrm & Mesa (Provides /dev/dri support).
- [x] Build Drivers (Hardware Abstraction):
    - [x] xf86-video-fbdev: To allow Xorg to use GeminiOS's current framebuffer.
    - [x] eudev (libudev): Required for device hotplugging and discovery.
    - [x] xf86-input-evdev: To translate kernel /dev/input/eventX to X11 events.
- [x] Build Essential X Utilities:
    - [x] xinit: To launch the 'startx' command.
    - [x] xkbcomp & xkeyboard-config: Handled in build.sh.
    - [x] setxkbmap: To handle the keyboard layouts defined in your TODOS.

# PHASE 3: SUPPORT SERVICES & TOOLKITS (The GTK Stack)
# XFCE4 is a GTK+ 3 application suite.
- [x] Build D-Bus (System Bus):
    - [x] Mandatory: XFCE components communicate via D-Bus.
    - [x] Update init.cpp to start 'dbus-daemon --system' on boot.
- [x] Build Font & Image Rendering:
    - [x] FreeType & Fontconfig: For high-quality text rendering.
    - [x] Libpng, Libjpeg-turbo, Libtiff: For icons and wallpapers.
- [x] Build GLib (The Foundation of GTK):
    - [x] Requires PCRE, Libffi, and Zlib.
- [x] Build GTK+ 3 Stack:
    - [x] Cairo: 2D graphics library.
    - [x] Pango: Text layout engine.
    - [x] Atk: Accessibility bridge.
    - [x] Gdk-Pixbuf: Image loading library.
    - [x] GTK+ 3.x: The actual widget toolkit.
- [ ] Build Essential Helpers (New additions):
    - [ ] libwnck: "Window Navigator Construction Kit" (Required for the Taskbar/Window Switcher).
    - [ ] hicolor-icon-theme: The fallback icon theme (Required to prevent invisible icons).
    - [ ] startup-notification: Startup feedback protocol (hourglass cursor).

# PHASE 4: XFCE4 CORE COMPONENTS
# These must be built in this specific order due to internal dependencies.
- [ ] libxfce4util: Basic utility library for XFCE.
- [ ] xfconf: Configuration storage system (requires D-Bus).
- [ ] libxfce4ui: Interface library for XFCE widgets.
- [ ] garcon: Freedesktop.org compliant menu implementation (REQUIRED for the Start Menu).
- [ ] exo: Application library for XFCE.
- [ ] xfwm4: The XFCE Window Manager (handles window borders/decorations).
- [ ] xfce4-panel: The taskbar, clock, and start menu.
- [ ] xfdesktop: Manages the desktop background and icons.
- [ ] xfce4-session: Manages login, logout, and startup apps.
- [ ] xfce4-settings: Configuration tools (display, mouse, keyboard).

# PHASE 5: ESSENTIAL XFCE APPLICATIONS
# Without these, the desktop environment is unusable (cannot browse files or type commands).
- [ ] tumbler: D-Bus service for file thumbnails (Required by Thunar).
- [ ] Thunar: The XFCE File Manager (Vital).
    - [ ] thunar-volman: Automatic management of removable drives/USBs.
- [ ] xfce4-terminal: The Terminal Emulator (Vital for system admin).
- [ ] xfce4-appfinder: Application launcher (Run dialog).
- [ ] xfce4-notifyd: Notification daemon (Required for system alerts/volume changes).
- [ ] mousepad: Lightweight text editor (Vital for editing configs).
- [ ] xfce4-power-manager: Manages screen blanking, battery, and sleep.

# PHASE 6: GEMINIOS INTEGRATION
- [ ] Environment Configuration:
    - [ ] Create /etc/X11/xinit/xinitrc to launch 'exec startxfce4'.
    - [ ] Populate /usr/share/fonts/ with standard TTF fonts (e.g., DejaVu).
    - [ ] Populate /usr/share/icons/ with a basic icon theme (e.g., Adwaita).
- [ ] Init Update:
    - [ ] Update src/init.cpp to handle the transition from TTY to a Display Manager (or start X manually).
- [ ] ISO Packaging:
    - [ ] Update build.sh to include all new .so files in rootfs/lib.
    - [ ] Expected ISO size growth: ~25MB -> ~350MB.


# DEPENDENCIES LIST SECTION FOR GTK3+ (plus x11), IN ORDER: 
### 1. Build Tools & Compilers

*These are required to configure and build the libraries that follow.*

```text
1.  python3        (Required for Meson, xcb-proto, and various scripts)
2.  meson          (The primary build system for modern GNOME/GTK stack)
3.  ninja          (The backend builder for Meson)
4.  pkg-config     (Crucial for finding libraries during compilation)
5.  bison          (Parser generator, needed for GObject-Introspection)
6.  flex           (Lexical analyzer, needed for GObject-Introspection)
7.  gperf          (Perfect hash generator, needed by libxcb/others)
8.  gettext        (Internationalization tools: msgfmt, xgettext)
9.  perl           (Required for OpenSSL, Automake, and various build scripts)
10. util-macros    (X.Org build macros, required for X11 protocol headers)

```

### 2. Low-Level System Dependencies

*These libraries provide the foundation for data types, XML parsing, and device access.*

```text
11. zlib           (Compression: Required by GLib, PNG, Cairo, Freetype)
12. libffi         (Foreign Function Interface: Vital for GObject)
13. pcre2          (Perl-Compatible Regex: Vital for GLib 2.73+)
14. util-linux     (Provides 'libmount' and 'libblkid': Vital for GLib/GIO)
15. expat          (XML Parser: Required by Fontconfig and D-Bus)
16. libxml2        (XML Parser: Required by shared-mime-info)
17. dbus           (IPC system: Required by Accessibility/AT-SPI)

```

### 3. The Core Object System (GLib)

*Must be built early as almost everything below links against it.*

```text
18. glib                    (The heart of GTK: GObject, GIO, GModule)
19. gobject-introspection   (Middleware: Generates binding metadata. Depends on GLib)

```

### 4. The X11 Protocol Stack (Priority 1)

*You cannot build graphical libraries until the X Window System protocols are installed. Order is extremely specific here.*

```text
20. xorgproto         (Merged X11 protocol headers)
21. libXau            (X Authorization Protocol)
22. libXdmcp          (X Display Manager Control Protocol)
23. xcb-proto         (XML descriptions of X protocols. Python required)
24. libxcb            (The C-binding for X. Depends on xcb-proto, Xau, Xdmcp)
25. xtrans            (Network API translation. Header-only, but vital)

```

### 5. The X11 Client Libraries (Priority 2)

*These wrap libxcb and provide the traditional X11 API used by Cairo and GTK.*

```text
26. libX11            (Core Client Lib. Depends on libxcb, xtrans, xorgproto)
27. libXext           (Common Extensions. Depends on libX11)
28. libXfixes         (Coordinate/Region fixes. Depends on libX11)
29. libXrender        (Alpha compositing. Depends on libX11)
30. libXdamage        (Screen damage tracking. Depends on libXfixes)
31. libXcomposite     (Window composition. Depends on libXfixes)
32. libXcursor        (Cursor management. Depends on libXrender, libXfixes)
33. libXi             (Input devices. Depends on libXext, libXfixes)
34. libXrandr         (Resize/Rotate. Depends on libXext, libXrender)
35. libXinerama       (Multi-monitor. Depends on libXext)
36. libXtst           (Record/Test extensions. Required for Accessibility)

```

### 6. Graphics & Font Primitives

*Libraries for handling raw pixel data, image formats, and font files.*

```text
37. libpng            (PNG support. Depends on zlib)
38. libjpeg-turbo     (JPEG support)
39. libtiff           (TIFF support. Depends on zlib, jpeg)
40. freetype          (Font engine. Depends on zlib, libpng)
41. fontconfig        (Font configuration. Depends on freetype, expat)
42. pixman            (Low-level pixel manipulation. Required by Cairo)

```

### 7. The Rendering Stack (Cairo & Pango)

*This is where the graphics stack comes together. Cairo draws; Pango formats text.*

```text
43. cairo             (2D Vector Graphics. MUST be built with --enable-xlib.
                       Depends on: pixman, fontconfig, freetype, png, X11, Xext, Xrender)

44. harfbuzz          (Text shaping engine. Depends on glib, freetype)
45. fribidi           (Bi-directional text algorithm. Depends on glib)

46. pango             (Text Layout. Depends on glib, cairo, harfbuzz, fribidi)

```

### 8. Assets & Accessibility

*Icons, Images, and Assistive Technologies.*

```text
47. shared-mime-info  (Database of file types. Depends on libxml2, glib)
48. gdk-pixbuf        (Image loading facility. Depends on glib, png, jpeg, tiff)

49. at-spi2-core      (Assistive Tech Service Provider. Depends on dbus, glib, Xtst)
50. at-spi2-atk       (Bridge for ATK. Depends on at-spi2-core)
51. atk               (Accessibility Toolkit. Depends on glib. Note: Sometimes merged
                       into at-spi2-core in very new versions, but distinct for GTK3)

```

### 9. Final Pre-Requisites

*The last few libraries required before the main event.*

```text
52. libepoxy          (OpenGL dispatch library. Replaces GLEW. Depends on Mesa headers)
53. libxkbcommon      (Keyboard keymap handling. Mandatory even for X11 backend)
54. hicolor-icon-theme(Base icon fallback theme. Runtime dependency for tests)
55. adwaita-icon-theme(Default GTK icon theme. Runtime dependency)

```

### 10. GTK+ 3 (The Target)

```text
56. gtk+ (3.24.x)
    
    Configuration Check:
    - Ensure dependencies above are found.
    - Explicitly enable X11 backend if needed (usually auto-detected):
      meson setup builddir -Dx11-backend=true ...

```
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
    - [x] xterm: Terminal emulator for X.
    - [x] xprop: Property displayer for X.

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
- [x] Build Essential Helpers (New additions):
    - [x] libwnck: "Window Navigator Construction Kit" (Required for the Taskbar/Window Switcher).
    - [x] hicolor-icon-theme: The fallback icon theme (Required to prevent invisible icons).
    - [x] startup-notification: Startup feedback protocol (hourglass cursor).
    - [x] libepoxy: OpenGL dispatch library.
    - [x] libxkbcommon: Keyboard keymap handling library.
    - [x] gsettings-desktop-schemas: Shared GSettings schemas.
    - [x] adwaita-icon-theme: Default GTK icon theme.

# PHASE 4: XFCE4 CORE COMPONENTS
# These were built and packaged as .gpkg files.
- [x] libxfce4util: Basic utility library for XFCE.
- [x] xfconf: Configuration storage system (requires D-Bus).
- [x] libxfce4ui: Interface library for XFCE widgets.
- [x] garcon: Freedesktop.org compliant menu implementation.
- [x] exo: Application library for Xfce.
- [x] xfwm4: The XFCE Window Manager.
- [x] xfce4-panel: The taskbar, clock, and start menu.
- [x] xfdesktop: Manages the desktop background and icons.
- [x] xfce4-session: Manages login, logout, and startup apps.
- [x] xfce4-settings: Configuration tools (display, mouse, keyboard).

# PHASE 5: # ESSENTIAL XFCE APPLICATIONS (for xfce4-utils package)
# Without these, the desktop environment is unusable (cannot browse files or type commands).
# Base Source: https://archive.xfce.org/src/xfce/
- [ ] tumbler: D-Bus service for file thumbnails (Required by Thunar).
- [ ] Thunar: The XFCE File Manager (Vital).
    - [ ] thunar-volman: Automatic management of removable drives/USBs.
- [ ] xfce4-terminal: The Terminal Emulator (Vital for system admin).
- [ ] xfce4-appfinder: Application launcher (Run dialog).
- [ ] xfce4-notifyd: Notification daemon (Required for system alerts/volume changes).
- [ ] mousepad: Lightweight text editor (Vital for editing configs).
- [ ] xfce4-power-manager: Manages screen blanking, battery, and sleep.

# XFCE4 GOODIES - STANDALONE APPLICATIONS
# Additional useful applications often included in the goodies metapackage.
# Base Source: https://archive.xfce.org/src/apps/
- [ ] ristretto: Lightweight image viewer.
- [ ] xfburn: CD/DVD burning application.
- [ ] xfce4-dict: Dictionary client to query different dictionaries.
- [ ] xfce4-screenshooter: Application to take screenshots.
- [ ] xfce4-taskmanager: Easy to use task manager/process viewer.
- [ ] gigolo: Frontend to manage connections to remote filesystems (GIO/GVfs).
- [ ] parole: Modern media player based on GStreamer.

# XFCE4 GOODIES - THUNAR PLUGINS
# Extensions specifically for the file manager.
# Base Source: https://archive.xfce.org/src/thunar-plugins/
- [ ] thunar-archive-plugin: Adds "Create Archive" and "Extract Here" to context menus.
- [ ] thunar-media-tags-plugin: Adds ID3/OGG tag support to file properties dialog.
- [ ] thunar-shares-plugin: Quickly share folders using Samba (optional but common).

# XFCE4 GOODIES - PANEL PLUGINS
# Applets that sit on the taskbar/panel.
# Base Source: https://archive.xfce.org/src/panel-plugins/
- [ ] xfce4-whiskermenu-plugin: Modern, searchable application menu (Popular alternative to default menu).
- [ ] xfce4-battery-plugin: Battery monitor for laptops.
- [ ] xfce4-clipman-plugin: Clipboard manager (History of copied text).
- [ ] xfce4-pulseaudio-plugin: Audio volume control (for PulseAudio/PipeWire systems).
- [ ] xfce4-cpufreq-plugin: CPU frequency scaling monitor.
- [ ] xfce4-cpugraph-plugin: Graphical representation of CPU load.
- [ ] xfce4-diskperf-plugin: Disk performance monitor (read/write speeds).
- [ ] xfce4-fsguard-plugin: Monitors free space on filesystems.
- [ ] xfce4-genmon-plugin: Generic monitor (runs custom scripts and displays output).
- [ ] xfce4-mailwatch-plugin: Multi-protocol mail checker.
- [ ] xfce4-netload-plugin: Network load monitor.
- [ ] xfce4-notes-plugin: Sticky notes for the desktop.
- [ ] xfce4-places-plugin: Quick access menu for folders, documents, and removable media.
- [ ] xfce4-sensors-plugin: Hardware sensors monitor (temperature/fan speed).
- [ ] xfce4-smartbookmark-plugin: Quick web search from the panel.
- [ ] xfce4-systemload-plugin: System load monitor (CPU, RAM, Swap usage).
- [ ] xfce4-timer-plugin: Simple countdown and alarm timer.
- [ ] xfce4-verve-plugin: Command line input on the panel.
- [ ] xfce4-wavelan-plugin: Wireless network stats.
- [ ] xfce4-weather-plugin: Weather information.
- [ ] xfce4-xkb-plugin: Keyboard layout switcher.

# PHASE 6: GEMINIOS INTEGRATION
- [ ] Environment Configuration:
    - [ ] Create /etc/X11/xinit/xinitrc to launch 'exec startxfce4'.
    - [/] Populate /usr/share/fonts/ with standard TTF fonts (e.g., DejaVu).
    - [x] Populate /usr/share/icons/ with a basic icon theme (e.g., Adwaita).
- [ ] Init Update:
    - [ ] Update src/init.cpp to handle the transition from TTY to a Display Manager (or start X manually).
- [ ] ISO Packaging:
    - [x] Update builder to include all new .so files in rootfs/lib.
    - [ ] Expected ISO size growth: ~25MB -> ~350MB.


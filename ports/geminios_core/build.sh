#!/bin/bash
set -e

echo "Installing Ginit Core..."
cd "$ROOT_DIR/ginit"
make install DESTDIR="$ROOTFS"
cd -

# Additional setup for ginit
# ginit Makefile now installs binaries to /bin and /sbin
# and services to /usr/lib/ginit/services

# The live initramfs hands off with switch_root /new_root /sbin/init.
# Keep a boot-compatible /sbin/init entrypoint, but do not ship /bin/init
# as a general user-facing command alias.
rm -f "$ROOTFS/init" "$ROOTFS/bin/init"
ln -sfn ../bin/ginit "$ROOTFS/sbin/init"

ln -sf bash "$ROOTFS/bin/sh"
ln -sf /bin/apps/system/gpkg "$ROOTFS/bin/gpkg"

# Create default system files (passwd, group, shadow)
mkdir -p "$ROOTFS/etc"
mkdir -p "$ROOTFS/etc/selinux"

# 1. /etc/passwd - Use /bin/bash as shell
cat > "$ROOTFS/etc/passwd" <<EOF
root:x:0:0:System Administrator:/root:/bin/bash
lightdm:x:620:620:Light Display Manager:/var/lib/lightdm:/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/var/run/dbus:/bin/false
EOF

# 2. /etc/group
cat > "$ROOTFS/etc/group" <<EOF
root:x:0:
bin:x:1:
sys:x:2:
kmem:x:9:
tty:x:5:
disk:x:6:
lp:x:7:
dialout:x:20:
cdrom:x:24:
sudo:x:27:root
audio:x:29:
video:x:44:
power:x:98:
storage:x:99:
users:x:100:
input:x:101:
render:x:102:
sgx:x:103:
tape:x:26:
kvm:x:78:
systemd-journal:x:190:
adm:x:191:
messagebus:x:18:
lightdm:x:620:
EOF

# 3. /etc/shadow
cat > "$ROOTFS/etc/shadow" <<EOF
root:\$5\$GEMINI_SALT\$eBv4S.VF3SzMsgDgFmF1JdfMnXTId9IOAZUzSXVN6P9:19000:0:99999:7:::
lightdm:!:19000:0:99999:7:::
messagebus:!:19000:0:99999:7:::
EOF
chmod 600 "$ROOTFS/etc/shadow"

# 4. Basic System Configuration (NSS, ld.so, symlinks)
cat > "$ROOTFS/etc/nsswitch.conf" <<EOF
passwd:         files
group:          files
shadow:         files
hosts:          files dns
networks:       files
protocols:      files
services:       files
ethers:         files
rpc:            files
EOF

cat > "$ROOTFS/etc/shells" <<EOF
/bin/sh
/bin/bash
EOF

# PS1 Configuration
cat > "$ROOTFS/etc/profile" <<EOF
export PATH=/bin/apps/system:/bin/apps:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin

if [ -f "\$HOME/.bashrc" ]; then
    . "\$HOME/.bashrc"
else
    export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\$ '
fi
EOF

mkdir -p "$ROOTFS/root"
cat > "$ROOTFS/root/.bashrc" <<EOF
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\$ '
EOF

mkdir -p "$ROOTFS/etc/skel"
cat > "$ROOTFS/etc/skel/.bashrc" <<EOF
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\$ '
EOF

cat > "$ROOTFS/etc/skel/.profile" <<'EOF'
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
EOF

mkdir -p "$ROOTFS/etc/pam.d" "$ROOTFS/etc/security" "$ROOTFS/etc/elogind/logind.conf.d"
mkdir -p "$ROOTFS/etc/geminios/session-env.d" "$ROOTFS/etc/xdg" "$ROOTFS/etc/xdg/autostart" "$ROOTFS/etc/xdg/fastfetch"
mkdir -p "$ROOTFS/usr/libexec/geminios/session-env.d"
mkdir -p "$ROOTFS/usr/share/fastfetch/logos"
mkdir -p "$ROOTFS/etc/lightdm/lightdm.conf.d"
mkdir -p "$ROOTFS/var/lib/lightdm/data" "$ROOTFS/var/cache/lightdm" "$ROOTFS/run/lightdm"
if [ "$(id -u)" -eq 0 ]; then
    chown -R 620:620 "$ROOTFS/var/lib/lightdm" "$ROOTFS/var/cache/lightdm"
else
    echo "[*] Skipping LightDM directory ownership fixups during unprivileged build; runtime setup must create/chown them on the target system."
fi

cat > "$ROOTFS/etc/environment" <<EOF
PATH=/bin/apps/system:/bin/apps:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin
LANG=C.UTF-8
EOF

FASTFETCH_ASSET_DIR="$ROOT_DIR/build_system/assets/fastfetch"
FASTFETCH_ASCII_SOURCE="$FASTFETCH_ASSET_DIR/geminios-ascii.txt"
FASTFETCH_ASCII_TARGET="$ROOTFS/usr/share/fastfetch/logos/geminios-ascii.txt"
FASTFETCH_RENDERED_TARGET="$ROOTFS/usr/share/fastfetch/logos/geminios-rainbow.ans"
cp "$FASTFETCH_ASCII_SOURCE" "$FASTFETCH_ASCII_TARGET"
python3 "$ROOT_DIR/tools/generate_fastfetch_logo.py" "$FASTFETCH_ASCII_SOURCE" "$FASTFETCH_RENDERED_TARGET"

cat > "$ROOTFS/etc/xdg/fastfetch/config.jsonc" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file-raw",
    "source": "/usr/share/fastfetch/logos/geminios-rainbow.ans",
    "padding": {
      "right": 2
    }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "uptime",
    "packages",
    "shell",
    "display",
    "de",
    "wm",
    "wmtheme",
    "theme",
    "icons",
    "font",
    "cursor",
    "terminal",
    "terminalfont",
    "cpu",
    "gpu",
    "memory",
    "swap",
    "disk",
    "localip",
    "battery",
    "poweradapter",
    "locale",
    "break",
    "colors"
  ]
}
EOF

cat > "$ROOTFS/etc/selinux/config" <<EOF
# GeminiOS SELinux defaults
SELINUX=enforcing
SELINUXTYPE=default
SETLOCALDEFS=0
EOF

mkdir -p "$ROOTFS/etc/default"
cat > "$ROOTFS/etc/default/locale" <<EOF
LANG=C.UTF-8
EOF

cat > "$ROOTFS/etc/security/limits.conf" <<EOF
# GeminiOS PAM limits defaults
*               soft    nofile          1024
*               hard    nofile          1048576
root            soft    nofile          1024
root            hard    nofile          1048576
EOF

cat > "$ROOTFS/etc/pam.d/system-auth" <<EOF
auth        required      pam_unix.so
EOF

cat > "$ROOTFS/etc/pam.d/system-account" <<EOF
account     required      pam_unix.so
EOF

cat > "$ROOTFS/etc/pam.d/system-session" <<EOF
session     required      pam_env.so readenv=1
session     required      pam_limits.so
session     required      pam_unix.so
session     optional      pam_loginuid.so
session     optional      pam_keyinit.so force revoke
session     optional      pam_selinux.so close
session     optional      pam_selinux.so open env_params
session     optional      pam_elogind.so
EOF

cat > "$ROOTFS/etc/pam.d/system-password" <<EOF
password    required      pam_unix.so yescrypt shadow try_first_pass
EOF

cat > "$ROOTFS/etc/pam.d/common-auth" <<EOF
auth        include       system-auth
EOF

cat > "$ROOTFS/etc/pam.d/common-account" <<EOF
account     include       system-account
EOF

cat > "$ROOTFS/etc/pam.d/common-session" <<EOF
session     include       system-session
EOF

cat > "$ROOTFS/etc/pam.d/common-session-noninteractive" <<EOF
session     include       system-session
EOF

cat > "$ROOTFS/etc/pam.d/common-password" <<EOF
password    include       system-password
EOF

cat > "$ROOTFS/etc/pam.d/login" <<EOF
auth        include       system-auth
account     include       system-account
password    include       system-password
session     include       system-session
session     optional      pam_lastlog.so silent
EOF

cat > "$ROOTFS/etc/pam.d/login-autologin" <<EOF
auth        sufficient    pam_permit.so
account     include       system-account
session     include       system-session
password    include       system-password
EOF

cat > "$ROOTFS/etc/pam.d/lightdm" <<EOF
auth        include       system-auth
account     include       system-account
password    include       system-password
session     include       system-session
EOF

cat > "$ROOTFS/etc/pam.d/lightdm-autologin" <<EOF
auth        sufficient    pam_permit.so
account     include       system-account
session     include       system-session
EOF

cat > "$ROOTFS/etc/pam.d/lightdm-greeter" <<EOF
#%PAM-1.0
auth         required pam_permit.so
account      include       common-account
password     include       common-password
session      include       common-session
session      required      pam_env.so readenv=1 envfile=/etc/default/locale
EOF

cat > "$ROOTFS/etc/pam.d/elogind-user" <<EOF
account     include       system-account
session     required      pam_env.so
session     required      pam_limits.so
session     required      pam_unix.so
session     optional      pam_loginuid.so
session     optional      pam_keyinit.so force revoke
session     optional      pam_elogind.so
auth        required      pam_deny.so
password    required      pam_deny.so
EOF

cat > "$ROOTFS/etc/pam.d/other" <<EOF
auth        required      pam_warn.so
auth        required      pam_deny.so
account     required      pam_warn.so
account     required      pam_deny.so
password    required      pam_warn.so
password    required      pam_deny.so
session     required      pam_warn.so
session     required      pam_deny.so
EOF

cat > "$ROOTFS/etc/elogind/logind.conf.d/10-geminios.conf" <<EOF
[Login]
KillUserProcesses=no
EOF

cat > "$ROOTFS/etc/lightdm/lightdm.conf.d/50-geminios.conf" <<EOF
[LightDM]
run-directory=/run/lightdm

[Seat:*]
display-setup-script=/usr/libexec/geminios/lightdm-prepare
greeter-session=lightdm-greeter
session-wrapper=/etc/lightdm/Xsession
EOF

cat > "$ROOTFS/etc/lightdm/Xsession" <<'EOF'
#!/bin/sh
if [ -f /etc/profile ]; then
    . /etc/profile
fi

export GEMINIOS_SESSION_TYPE="${GEMINIOS_SESSION_TYPE:-x11}"
export GEMINIOS_SESSION_DESKTOP="${GEMINIOS_SESSION_DESKTOP:-lightdm}"
if [ -r /usr/libexec/geminios/session-common ]; then
    . /usr/libexec/geminios/session-common
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

exec /bin/bash --login
EOF
chmod 755 "$ROOTFS/etc/lightdm/Xsession"

# Merge LightDM & PAM from staging without importing foreign DBus runtime
# binaries or libraries. Those must remain owned by the GeminiOS base image or
# by gpkg-managed upgrades, otherwise desktop sessions can end up with a
# mismatched dbus-launch/libdbus pair.
should_skip_lightdm_stage_path() {
    case "$1" in
        bin/dbus-*|sbin/dbus-*|usr/bin/dbus-*|usr/sbin/dbus-*|usr/libexec/dbus-*|usr/lib/libdbus-1.so*|usr/lib64/libdbus-1.so*|lib/libdbus-1.so*|lib64/libdbus-1.so*|usr/lib/x86_64-linux-gnu/libdbus-1.so*|usr/lib64/x86_64-linux-gnu/libdbus-1.so*|lib/x86_64-linux-gnu/libdbus-1.so*|lib64/x86_64-linux-gnu/libdbus-1.so*|etc/dbus-1|etc/dbus-1/*|usr/share/dbus-1|usr/share/dbus-1/*|usr/lib/dbus-1.0|usr/lib/dbus-1.0/*|usr/lib64/dbus-1.0|usr/lib64/dbus-1.0/*)
            return 0
            ;;
    esac
    return 1
}

if [ -d "$ROOTFS/staging/lightdm" ]; then
    echo "Merging LightDM & PAM from staging (DBus payload filtered)..."
    while IFS= read -r -d '' staged_dir; do
        rel_path="${staged_dir#$ROOTFS/staging/lightdm/}"
        if should_skip_lightdm_stage_path "$rel_path"; then
            echo "[*] Skipping staged DBus directory: $rel_path"
            continue
        fi
        mkdir -p "$ROOTFS/$rel_path"
    done < <(find "$ROOTFS/staging/lightdm" -mindepth 1 -type d -print0)

    while IFS= read -r -d '' staged_path; do
        rel_path="${staged_path#$ROOTFS/staging/lightdm/}"
        if should_skip_lightdm_stage_path "$rel_path"; then
            echo "[*] Skipping staged DBus payload: $rel_path"
            continue
        fi
        dest_path="$ROOTFS/$rel_path"
        mkdir -p "$(dirname "$dest_path")"
        cp -a "$staged_path" "$dest_path"
    done < <(find "$ROOTFS/staging/lightdm" -mindepth 1 ! -type d -print0)
fi

# Re-apply GeminiOS LightDM overrides after the staged package merge so the
# distro defaults do not overwrite the custom greeter/session policy.
cat > "$ROOTFS/etc/pam.d/lightdm-greeter" <<EOF
#%PAM-1.0
auth         required pam_permit.so
account      include       common-account
password     include       common-password
session      include       common-session
session      required      pam_env.so readenv=1 envfile=/etc/default/locale
EOF

cat > "$ROOTFS/etc/lightdm/lightdm.conf.d/50-geminios.conf" <<EOF
[LightDM]
run-directory=/run/lightdm

[Seat:*]
display-setup-script=/usr/libexec/geminios/lightdm-prepare
greeter-session=lightdm-greeter
session-wrapper=/etc/lightdm/Xsession
EOF

cat > "$ROOTFS/etc/lightdm/lightdm.conf" <<EOF
[LightDM]
run-directory=/run/lightdm

[Seat:*]
display-setup-script=/usr/libexec/geminios/lightdm-prepare
greeter-session=lightdm-greeter
session-wrapper=/etc/lightdm/Xsession
EOF

cat > "$ROOTFS/etc/lightdm/Xsession" <<'EOF'
#!/bin/sh
if [ -f /etc/profile ]; then
    . /etc/profile
fi

export GEMINIOS_SESSION_TYPE="${GEMINIOS_SESSION_TYPE:-x11}"
export GEMINIOS_SESSION_DESKTOP="${GEMINIOS_SESSION_DESKTOP:-lightdm}"
if [ -r /usr/libexec/geminios/session-common ]; then
    . /usr/libexec/geminios/session-common
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

exec /bin/bash --login
EOF
chmod 755 "$ROOTFS/etc/lightdm/Xsession"

cat > "$ROOTFS/etc/ld.so.conf" <<EOF
/lib/x86_64-linux-gnu
/usr/lib/x86_64-linux-gnu
/lib
/usr/lib
/usr/local/lib
include /etc/ld.so.conf.d/*.conf
EOF
mkdir -p "$ROOTFS/etc/ld.so.conf.d"

# Debian-style PAM compatibility for packages that expect pam_systemd.so while
# GeminiOS provides elogind instead of the full systemd init/session stack.
mkdir -p \
    "$ROOTFS/lib/x86_64-linux-gnu/security" \
    "$ROOTFS/usr/lib/x86_64-linux-gnu/security"
ln -sfn pam_elogind.so "$ROOTFS/usr/lib/x86_64-linux-gnu/security/pam_systemd.so"
ln -sfn pam_elogind.so "$ROOTFS/lib/x86_64-linux-gnu/security/pam_systemd.so"

mkdir -p "$ROOTFS/usr/libexec/geminios"
cat > "$ROOTFS/usr/libexec/geminios/elogind-launch" <<'EOF'
#!/bin/sh
for candidate in \
    /usr/libexec/elogind \
    /usr/lib/elogind/elogind \
    /usr/libexec/elogind/elogind \
    /usr/lib/x86_64-linux-gnu/elogind/elogind
do
    if [ -x "$candidate" ]; then
        exec "$candidate" "$@"
    fi
done

echo "E: elogind daemon not found in expected locations." >&2
exit 1
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/elogind-launch"

mkdir -p "$ROOTFS/etc/modules-load.d"
cat > "$ROOTFS/etc/modules-load.d/fuse.conf" <<'EOF'
# Hint for future module-load integration.
fuse
EOF

cat > "$ROOTFS/usr/libexec/geminios/ensure-fuse-device" <<'EOF'
#!/bin/sh
set -eu

find_fuse_dev_numbers() {
    if [ -r /sys/class/misc/fuse/dev ]; then
        cat /sys/class/misc/fuse/dev
        return 0
    fi

    if [ -r /proc/misc ]; then
        minor="$(grep ' fuse$' /proc/misc 2>/dev/null | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]\+fuse$/\1/p')"
        if [ -n "${minor:-}" ]; then
            printf '10:%s\n' "$minor"
            return 0
        fi
    fi

    return 1
}

ensure_fuse_node() {
    dev_numbers="$(find_fuse_dev_numbers || true)"
    [ -n "$dev_numbers" ] || return 1

    major="${dev_numbers%:*}"
    minor="${dev_numbers#*:}"
    [ -n "$major" ] && [ -n "$minor" ] || return 1

    mkdir -p /dev
    if [ ! -e /dev/fuse ]; then
        mknod -m 666 /dev/fuse c "$major" "$minor"
    fi
    chmod 666 /dev/fuse || true
    return 0
}

try_modprobe_fuse() {
    for tool in /usr/bin/modprobe /usr/sbin/modprobe /bin/modprobe /sbin/modprobe; do
        if [ -x "$tool" ]; then
            "$tool" fuse >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

if [ -e /dev/fuse ]; then
    chmod 666 /dev/fuse >/dev/null 2>&1 || true
    exit 0
fi

if ensure_fuse_node; then
    exit 0
fi

try_modprobe_fuse || true

if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=misc >/dev/null 2>&1 || true
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
fi

if ensure_fuse_node; then
    exit 0
fi

echo "[fuse-device] /dev/fuse is unavailable; FUSE-backed features such as GVfs mounts may not work." >&2
exit 0
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/ensure-fuse-device"

cat > "$ROOTFS/usr/libexec/geminios/lightdm-prepare" <<'EOF'
#!/bin/sh
set -e

mkdir -p /run/lightdm
mkdir -p /var/lib/lightdm/data
mkdir -p /var/cache/lightdm

if getent passwd lightdm >/dev/null 2>&1; then
    chown -R lightdm:lightdm /var/lib/lightdm /var/cache/lightdm || true
    chmod 700 /var/lib/lightdm || true
    touch /var/lib/lightdm/.Xauthority
    chown lightdm:lightdm /var/lib/lightdm/.Xauthority || true
    chmod 600 /var/lib/lightdm/.Xauthority || true
fi
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/lightdm-prepare"

mkdir -p "$ROOTFS/usr/share/xgreeters"
cat > "$ROOTFS/usr/libexec/geminios/lightdm-greeter-launch" <<'EOF'
#!/bin/sh
for candidate in \
    /usr/sbin/lightdm-gtk-greeter \
    /usr/bin/lightdm-gtk-greeter \
    /usr/sbin/slick-greeter \
    /usr/bin/slick-greeter \
    /usr/sbin/unity-greeter \
    /usr/bin/unity-greeter
do
    if [ -x "$candidate" ]; then
        exec "$candidate" "$@"
    fi
done

echo "E: no supported LightDM greeter binary found." >&2
exit 1
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/lightdm-greeter-launch"

cat > "$ROOTFS/usr/share/xgreeters/lightdm-greeter.desktop" <<'EOF'
[Desktop Entry]
Name=LightDM Greeter
Comment=GeminiOS LightDM greeter launcher
Exec=/usr/libexec/geminios/lightdm-greeter-launch
Type=Application
EOF

# Compatibility shim for Debian desktop packages linked against GTK Wayland
# helpers when GeminiOS is still running an X11 session stack.
mkdir -p "$ROOTFS/usr/lib/x86_64-linux-gnu"
gcc -shared -fPIC "$ROOT_DIR/build_system/gdk_wayland_compat.c" \
    -o "$ROOTFS/usr/lib/x86_64-linux-gnu/libgdk-wayland-compat.so"

cat > "$ROOTFS/usr/libexec/geminios/session-common" <<'EOF'
#!/bin/sh

if [ -f /etc/profile ]; then
    . /etc/profile
fi

geminios_source_shell_dropins() {
    for dropin_dir in "$@"; do
        [ -d "$dropin_dir" ] || continue
        for dropin in "$dropin_dir"/*.sh; do
            [ -r "$dropin" ] || continue
            . "$dropin"
        done
    done
}

geminios_guess_vtnr() {
    current_tty="$(readlink /proc/self/fd/0 2>/dev/null || true)"
    case "$current_tty" in
        /dev/tty[0-9]*)
            basename "$current_tty" | sed 's/[^0-9]//g'
            ;;
    esac
}

geminios_update_activation_environment() {
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment \
            DISPLAY \
            WAYLAND_DISPLAY \
            XDG_CACHE_HOME \
            XDG_CONFIG_HOME \
            XDG_CURRENT_DESKTOP \
            XDG_DATA_HOME \
            XDG_DATA_DIRS \
            XDG_MENU_PREFIX \
            XDG_RUNTIME_DIR \
            XDG_SEAT \
            XDG_SESSION_CLASS \
            XDG_SESSION_DESKTOP \
            XDG_SESSION_ID \
            XDG_SESSION_TYPE \
            XDG_STATE_HOME \
            XDG_VTNR \
            DESKTOP_SESSION \
            DBUS_SESSION_BUS_ADDRESS \
            GDK_BACKEND \
            GTK_USE_PORTAL \
            QT_QPA_PLATFORM \
            SDL_VIDEODRIVER \
            CLUTTER_BACKEND \
            MOZ_ENABLE_WAYLAND \
            ELECTRON_OZONE_PLATFORM_HINT \
            GNOME_KEYRING_CONTROL >/dev/null 2>&1 || true
    fi
}

export XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS:-/etc/xdg}"
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export XDG_SESSION_CLASS="${XDG_SESSION_CLASS:-user}"

if [ -n "${GEMINIOS_SESSION_TYPE:-}" ] && [ -z "${XDG_SESSION_TYPE:-}" ]; then
    export XDG_SESSION_TYPE="$GEMINIOS_SESSION_TYPE"
fi

if [ -n "${GEMINIOS_SESSION_DESKTOP:-}" ]; then
    export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-$GEMINIOS_SESSION_DESKTOP}"
    export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-$GEMINIOS_SESSION_DESKTOP}"
    export DESKTOP_SESSION="${DESKTOP_SESSION:-$GEMINIOS_SESSION_DESKTOP}"
fi

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
mkdir -p "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

if [ ! -d "$XDG_RUNTIME_DIR" ] || [ ! -w "$XDG_RUNTIME_DIR" ]; then
    echo "E: XDG_RUNTIME_DIR ($XDG_RUNTIME_DIR) is not usable for $(id -un)." >&2
    return 1 2>/dev/null || exit 1
fi

if [ -z "${XDG_VTNR:-}" ]; then
    xdg_vtnr="$(geminios_guess_vtnr)"
    if [ -n "$xdg_vtnr" ]; then
        export XDG_VTNR="$xdg_vtnr"
    fi
fi

if [ -z "${XDG_SEAT:-}" ] && [ -e /run/systemd/seats/seat0 ]; then
    export XDG_SEAT="seat0"
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

case "${XDG_SESSION_TYPE:-tty}" in
    wayland)
        export GDK_BACKEND="${GDK_BACKEND:-wayland,x11}"
        export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
        export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
        export CLUTTER_BACKEND="${CLUTTER_BACKEND:-wayland}"
        export MOZ_ENABLE_WAYLAND="${MOZ_ENABLE_WAYLAND:-1}"
        export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
        if command -v xdg-desktop-portal >/dev/null 2>&1; then
            export GTK_USE_PORTAL="${GTK_USE_PORTAL:-1}"
        fi
        ;;
    x11)
        export GDK_BACKEND="${GDK_BACKEND:-x11}"
        export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
        export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-x11}"
        ;;
esac

if [ "${XDG_CURRENT_DESKTOP:-}" = "GNOME" ] || [ "${XDG_SESSION_DESKTOP:-}" = "GNOME" ]; then
    export XDG_MENU_PREFIX="${XDG_MENU_PREFIX:-gnome-}"
fi

geminios_source_shell_dropins \
    /usr/libexec/geminios/session-env.d \
    /etc/geminios/session-env.d \
    "$XDG_CONFIG_HOME/geminios/session-env.d"

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

geminios_update_activation_environment
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/session-common"

cat > "$ROOTFS/usr/libexec/geminios/session-runtime" <<'EOF'
#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
    echo "Usage: session-runtime <x11|wayland> <desktop> <command> [args...]" >&2
    exit 2
fi

export GEMINIOS_SESSION_TYPE="$1"
export GEMINIOS_SESSION_DESKTOP="$2"
shift 2

. /usr/libexec/geminios/session-common

user_id="$(id -u)"
bg_pids=""
session_pid=""

start_bg_process() {
    pattern="$1"
    shift
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -u "$user_id" -f "$pattern" >/dev/null 2>&1; then
        return 0
    fi
    "$@" >/dev/null 2>&1 &
    bg_pids="$bg_pids $!"
}

find_candidate() {
    for candidate in "$@"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

cleanup() {
    if [ -n "$session_pid" ]; then
        kill "$session_pid" >/dev/null 2>&1 || true
        wait "$session_pid" >/dev/null 2>&1 || true
    fi
    for pid in $bg_pids; do
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT HUP INT TERM

wait_for_wayland_display() {
    if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi

    attempts=50
    while [ "$attempts" -gt 0 ]; do
        socket_path="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | sort | head -n 1)"
        if [ -n "$socket_path" ]; then
            export WAYLAND_DISPLAY="$(basename "$socket_path")"
            return 0
        fi
        sleep 0.1
        attempts=$((attempts - 1))
    done

    echo "[*] Waiting for a Wayland display timed out in $XDG_RUNTIME_DIR." >&2
}

start_graphical_helpers() {
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi

    geminios_update_activation_environment

    if command -v xdg-permission-store >/dev/null 2>&1; then
        start_bg_process "xdg-permission-store" xdg-permission-store
    fi
    if command -v xdg-document-portal >/dev/null 2>&1; then
        start_bg_process "xdg-document-portal" xdg-document-portal
    fi

    if command -v xdg-desktop-portal >/dev/null 2>&1; then
        start_bg_process "xdg-desktop-portal" xdg-desktop-portal
    fi
    if command -v xdg-desktop-portal-gtk >/dev/null 2>&1; then
        start_bg_process "xdg-desktop-portal-gtk" xdg-desktop-portal-gtk
    fi
    if command -v xdg-desktop-portal-gnome >/dev/null 2>&1; then
        start_bg_process "xdg-desktop-portal-gnome" xdg-desktop-portal-gnome
    fi

    polkit_agent="$(find_candidate \
        /usr/libexec/polkit-gnome-authentication-agent-1 \
        /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
        /usr/libexec/polkit-kde-authentication-agent-1 \
        /usr/lib/polkit-kde-1/polkit-kde-authentication-agent-1 \
        /usr/bin/lxqt-policykit-agent \
        /usr/libexec/mate-polkit \
        /usr/lib/mate-polkit/polkit-mate-authentication-agent-1 || true)"
    if [ -n "$polkit_agent" ]; then
        start_bg_process "$polkit_agent" "$polkit_agent"
    fi
}

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    xdg-user-dirs-update >/dev/null 2>&1 || true
fi

if command -v at-spi-bus-launcher >/dev/null 2>&1; then
    start_bg_process "at-spi-bus-launcher" at-spi-bus-launcher --launch-immediately
fi

if command -v gnome-keyring-daemon >/dev/null 2>&1; then
    keyring_env="$(gnome-keyring-daemon --start --components=secrets,pkcs11 2>/dev/null || true)"
    if [ -n "$keyring_env" ]; then
        eval "$keyring_env"
        export GNOME_KEYRING_CONTROL GNOME_KEYRING_PID
        geminios_update_activation_environment
    fi
fi

if command -v pipewire >/dev/null 2>&1; then
    start_bg_process "pipewire" pipewire
fi
if command -v wireplumber >/dev/null 2>&1; then
    start_bg_process "wireplumber" wireplumber
fi
if command -v pipewire-pulse >/dev/null 2>&1; then
    start_bg_process "pipewire-pulse" pipewire-pulse
fi

"$@" &
session_pid="$!"

wait_for_wayland_display
geminios_update_activation_environment
start_graphical_helpers

if wait "$session_pid"; then
    session_status=0
else
    session_status="$?"
fi
session_pid=""
exit "$session_status"
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/session-runtime"

cat > "$ROOTFS/usr/libexec/geminios/session-launch" <<'EOF'
#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
    echo "Usage: session-launch <x11|wayland> <desktop> <command> [args...]" >&2
    exit 2
fi

session_type="$1"
desktop="$2"
shift 2

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- /usr/libexec/geminios/session-runtime "$session_type" "$desktop" "$@"
fi

exec /usr/libexec/geminios/session-runtime "$session_type" "$desktop" "$@"
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/session-launch"

cat > "$ROOTFS/usr/libexec/geminios/wayland-session-report" <<'EOF'
#!/bin/sh
set -eu

if [ -r /usr/libexec/geminios/session-common ]; then
    . /usr/libexec/geminios/session-common
fi

print_row() {
    printf '%-24s %s\n' "$1" "$2"
}

report_binary() {
    name="$1"
    if path="$(command -v "$name" 2>/dev/null)"; then
        print_row "$name" "$path"
    else
        print_row "$name" "missing"
    fi
}

report_device() {
    path="$1"
    if [ -e "$path" ]; then
        details="$(ls -ld "$path" 2>/dev/null | tr -s ' ')"
        print_row "$path" "$details"
    else
        print_row "$path" "missing"
    fi
}

session_id="${XDG_SESSION_ID:-}"
if [ -z "$session_id" ] && command -v loginctl >/dev/null 2>&1; then
    session_id="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$(id -un)" '$3 == user { print $1; exit }')"
fi

echo "GeminiOS Wayland Session Report"
echo
print_row "user" "$(id -un) ($(id -u))"
print_row "groups" "$(id -Gn)"
print_row "session type" "${XDG_SESSION_TYPE:-unset}"
print_row "desktop" "${XDG_CURRENT_DESKTOP:-unset}"
print_row "session desktop" "${XDG_SESSION_DESKTOP:-unset}"
print_row "session id" "${session_id:-unset}"
print_row "seat" "${XDG_SEAT:-unset}"
print_row "vt" "${XDG_VTNR:-unset}"
print_row "runtime dir" "${XDG_RUNTIME_DIR:-unset}"
print_row "dbus session" "${DBUS_SESSION_BUS_ADDRESS:-unset}"
print_row "wayland display" "${WAYLAND_DISPLAY:-unset}"
print_row "display" "${DISPLAY:-unset}"

echo
echo "Runtime sockets"
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    found_socket=false
    for socket_path in "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/bus; do
        [ -S "$socket_path" ] || continue
        print_row "$(basename "$socket_path")" "$socket_path"
        found_socket=true
    done
    if [ "$found_socket" = false ]; then
        echo "none"
    fi
else
    echo "runtime directory is unavailable"
fi

echo
echo "Device access"
report_device /dev/dri/card0
report_device /dev/dri/renderD128
report_device /dev/input/event0

echo
echo "Session tools"
report_binary loginctl
report_binary dbus-run-session
report_binary dbus-update-activation-environment
report_binary Xwayland
report_binary xdg-desktop-portal
report_binary xdg-desktop-portal-gtk
report_binary xdg-desktop-portal-gnome
report_binary pipewire
report_binary wireplumber
report_binary pipewire-pulse
report_binary gnome-keyring-daemon
report_binary gnome-session
report_binary weston

if [ -n "$session_id" ] && command -v loginctl >/dev/null 2>&1; then
    echo
    echo "loginctl show-session"
    loginctl show-session "$session_id" \
        -p Id \
        -p Name \
        -p State \
        -p Active \
        -p Class \
        -p Type \
        -p Seat \
        -p VTNr 2>/dev/null || true
fi
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/wayland-session-report"

cat > "$ROOTFS/bin/wayland-session-report" <<'EOF'
#!/bin/sh
exec /usr/libexec/geminios/wayland-session-report "$@"
EOF
chmod 755 "$ROOTFS/bin/wayland-session-report"

cat > "$ROOTFS/bin/startxfce4" <<'EOF'
#!/bin/sh
REAL_STARTXFCE4="/usr/bin/startxfce4"

if [ ! -x "$REAL_STARTXFCE4" ]; then
    echo "E: $REAL_STARTXFCE4 was not found." >&2
    exit 1
fi

if [ ! -f /usr/lib/x86_64-linux-gnu/pkgconfig/gdk-wayland-3.0.pc ] && [ -r /usr/lib/x86_64-linux-gnu/libgdk-wayland-compat.so ]; then
    export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libgdk-wayland-compat.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

exec /usr/libexec/geminios/session-launch x11 XFCE "$REAL_STARTXFCE4" "$@"
EOF
chmod 755 "$ROOTFS/bin/startxfce4"

cat > "$ROOTFS/bin/startwayland" <<'EOF'
#!/bin/sh
set -eu

desktop="${GEMINIOS_WAYLAND_DESKTOP:-GeminiOS}"

if [ "$#" -eq 0 ]; then
    if command -v weston >/dev/null 2>&1; then
        set -- weston
    else
        echo "E: no Wayland compositor command was provided and weston is not installed." >&2
        exit 1
    fi
fi

exec /usr/libexec/geminios/session-launch wayland "$desktop" "$@"
EOF
chmod 755 "$ROOTFS/bin/startwayland"

cat > "$ROOTFS/bin/startweston" <<'EOF'
#!/bin/sh
set -eu

if command -v weston >/dev/null 2>&1; then
    exec env GEMINIOS_WAYLAND_DESKTOP=Weston /bin/startwayland weston "$@"
fi

echo "E: weston is not installed." >&2
exit 1
EOF
chmod 755 "$ROOTFS/bin/startweston"

cat > "$ROOTFS/bin/startgnome-wayland" <<'EOF'
#!/bin/sh
set -eu

export GNOME_SHELL_SESSION_MODE="${GNOME_SHELL_SESSION_MODE:-user}"
exec env GEMINIOS_WAYLAND_DESKTOP=GNOME /bin/startwayland /usr/libexec/geminios/gnome-session-entry "$@"
EOF
chmod 755 "$ROOTFS/bin/startgnome-wayland"

cat > "$ROOTFS/usr/libexec/geminios/gnome-session-entry" <<'EOF'
#!/bin/sh
set -eu

user_id="$(id -u)"
bg_pids=""

start_bg_process() {
    pattern="$1"
    shift
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -u "$user_id" -f "$pattern" >/dev/null 2>&1; then
        return 0
    fi
    "$@" >/dev/null 2>&1 &
    bg_pids="$bg_pids $!"
}

cleanup() {
    for pid in $bg_pids; do
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT HUP INT TERM

have_user_systemd_bus() {
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || ! command -v dbus-send >/dev/null 2>&1; then
        return 1
    fi
    dbus-send --session --print-reply \
        --dest=org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 \
        org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
}

export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-GNOME}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-GNOME}"
export DESKTOP_SESSION="${DESKTOP_SESSION:-GNOME}"
export XDG_MENU_PREFIX="${XDG_MENU_PREFIX:-gnome-}"
export GNOME_SHELL_SESSION_MODE="${GNOME_SHELL_SESSION_MODE:-user}"
export GSETTINGS_BACKEND="${GSETTINGS_BACKEND:-dconf}"

if have_user_systemd_bus && command -v gnome-session >/dev/null 2>&1; then
    exec gnome-session --session=gnome "$@"
fi

if ! command -v gnome-shell >/dev/null 2>&1; then
    echo "E: GNOME requires either gnome-session with a user systemd bus or a standalone gnome-shell binary." >&2
    exit 1
fi

echo "[*] org.freedesktop.systemd1 is unavailable on the user bus; starting standalone GNOME Shell mode." >&2
echo "[*] This is a GeminiOS compatibility path, not a full upstream gnome-session environment." >&2

if command -v gnome-settings-daemon >/dev/null 2>&1; then
    start_bg_process "gnome-settings-daemon" gnome-settings-daemon
fi
if command -v gnome-shell-calendar-server >/dev/null 2>&1; then
    start_bg_process "gnome-shell-calendar-server" gnome-shell-calendar-server
fi
if command -v ibus-daemon >/dev/null 2>&1; then
    start_bg_process "ibus-daemon" ibus-daemon --replace --xim
fi

exec gnome-shell --wayland --display-server "$@"
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/gnome-session-entry"

# Prepare runtime/session paths used by Wayland-capable applications.
mkdir -p "$ROOTFS/run/user"
chmod 755 "$ROOTFS/run/user"
mkdir -p "$ROOTFS/run/systemd" "$ROOTFS/run/systemd/inhibit" "$ROOTFS/run/systemd/seats"
mkdir -p "$ROOTFS/run/systemd/sessions" "$ROOTFS/run/systemd/users" "$ROOTFS/var/lib/elogind"
mkdir -p "$ROOTFS/usr/share/wayland-sessions"

cat > "$ROOTFS/usr/share/wayland-sessions/geminios-weston.desktop" <<'EOF'
[Desktop Entry]
Name=Weston
Comment=Weston Wayland compositor session
Exec=/bin/startweston
Type=Application
DesktopNames=Weston
EOF

cat > "$ROOTFS/usr/share/wayland-sessions/geminios-gnome.desktop" <<'EOF'
[Desktop Entry]
Name=GNOME
Comment=GNOME Shell on Wayland
Exec=/bin/startgnome-wayland
Type=Application
DesktopNames=GNOME
EOF

# Fix /var/run -> /run
mkdir -p "$ROOTFS/var"
rm -rf "$ROOTFS/var/run"
ln -sf /run "$ROOTFS/var/run"

# 5. Xorg Configuration
mkdir -p "$ROOTFS/etc/X11"
mkdir -p "$ROOTFS/var/lib/xkb"
mkdir -p "$ROOTFS/usr/share/X11/xkb"
chmod 777 "$ROOTFS/var/lib/xkb"
# Ensure compiled directory points to writable location
rm -rf "$ROOTFS/usr/share/X11/xkb/compiled"
ln -sf /var/lib/xkb "$ROOTFS/usr/share/X11/xkb/compiled"

mkdir -p "$ROOTFS/tmp/.X11-unix"
chmod 1777 "$ROOTFS/tmp/.X11-unix"

cat > "$ROOTFS/etc/X11/xorg.conf" <<EOF
Section "Files"
    ModulePath "/usr/lib/xorg/modules"
    ModulePath "/usr/lib/x86_64-linux-gnu/xorg/modules"
    ModulePath "/usr/lib/x86_64-linux-gnu/dri"
    XkbDir "/usr/share/X11/xkb"
    FontPath "/usr/share/fonts/X11/misc"
    FontPath "/usr/share/fonts/X11/TTF"
    FontPath "/usr/share/fonts/X11/OTF"
    FontPath "/usr/share/fonts/X11/Type1"
    FontPath "/usr/share/fonts/X11/75dpi"
    FontPath "/usr/share/fonts/X11/100dpi"
EndSection

Section "Module"
    Load "glx"
    Load "dri"
    Load "dri2"
    Load "dri3"
EndSection

Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AllowEmptyInput" "true"
    Option "AIGLX" "true"
EndSection

Section "InputClass"
    Identifier "evdev keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection

Section "InputClass"
    Identifier "evdev pointer catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection

Section "Device"
    Identifier "Card0"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card0"
    Option "SWcursor" "on"
EndSection

Section "Monitor"
    Identifier "Monitor0"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Card0"
    Monitor "Monitor0"
    DefaultDepth 24
EndSection
EOF

# Cleanup (don't remove signals.o and user_mgmt.o, geminios_complex needs them)
echo "Cleaning up compiled artifacts..."
rm -f ginit login getty init gpkg gpkg-worker

#!/bin/bash
set -e

echo "Installing Ginit Core..."
cd "$ROOT_DIR/ginit"
make install DESTDIR="$ROOTFS"
cd -

# Additional setup for ginit
# ginit Makefile now installs binaries to /bin and /sbin
# and services to /usr/lib/ginit/services

# Ensure /init points to /bin/ginit (PID 1)
cp "$ROOTFS/bin/ginit" "$ROOTFS/init"
ln -sf ginit "$ROOTFS/bin/init"

ln -sf bash "$ROOTFS/bin/sh"
ln -sf /bin/apps/system/gpkg "$ROOTFS/bin/gpkg"

# Create default system files (passwd, group, shadow)
mkdir -p "$ROOTFS/etc"

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
root:\$5\$GEMINI_SALT\$4813494d137e1631bba301d5acab6e7bb7aa74ce1185d456565ef51d737677b2:19000:0:99999:7:::
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

mkdir -p "$ROOTFS/etc/pam.d" "$ROOTFS/etc/security" "$ROOTFS/etc/elogind/logind.conf.d"
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
auth        required      pam_env.so
auth        required      pam_permit.so
account     required      pam_permit.so
password    required      pam_deny.so
session     required      pam_unix.so
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

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

exec /bin/bash --login
EOF
chmod 755 "$ROOTFS/etc/lightdm/Xsession"

# Merge LightDM & PAM from staging (Comprehensive Merge)
if [ -d "$ROOTFS/staging/lightdm" ]; then
    echo "Merging LightDM & PAM from staging..."
    
    # Merge directories
    for dir in etc lib lib64 sbin usr bin; do
        if [ -d "$ROOTFS/staging/lightdm/$dir" ]; then
            # Create destination if not exists (handling lib/lib64 symlinks automatically by shell expansion usually, 
            # but cp -r to a symlink copies INTO the target dir, which is what we want)
            # We use cp -rn to not overwrite existing critical files if conflicts, 
            # BUT for lightdm we might want to overwrite (e.g. pam configs).
            # Let's use cp -r and force overwrite for now to ensure we get the lightdm files.
            cp -rf "$ROOTFS/staging/lightdm/$dir/"* "$ROOTFS/$dir/" || true
        fi
    done
fi

# Re-apply GeminiOS LightDM overrides after the staged package merge so the
# distro defaults do not overwrite the custom greeter/session policy.
cat > "$ROOTFS/etc/pam.d/lightdm-greeter" <<EOF
auth        required      pam_env.so
auth        required      pam_permit.so
account     required      pam_permit.so
password    required      pam_deny.so
session     required      pam_unix.so
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

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

exec /bin/bash --login
EOF
chmod 755 "$ROOTFS/etc/lightdm/Xsession"

cat > "$ROOTFS/etc/ld.so.conf" <<EOF
/lib64
/lib64/x86_64-linux-gnu
/usr/lib64
/usr/lib64/x86_64-linux-gnu
/usr/local/lib64
/lib
/lib/x86_64-linux-gnu
/usr/lib
/usr/lib/x86_64-linux-gnu
/usr/local/lib
include /etc/ld.so.conf.d/*.conf
EOF
mkdir -p "$ROOTFS/etc/ld.so.conf.d"

# Debian-style PAM compatibility for packages that expect pam_systemd.so while
# GeminiOS provides elogind instead of the full systemd init/session stack.
mkdir -p \
    "$ROOTFS/usr/lib64/security" \
    "$ROOTFS/lib64/security" \
    "$ROOTFS/lib/x86_64-linux-gnu/security" \
    "$ROOTFS/usr/lib/x86_64-linux-gnu/security"
ln -sfn /usr/lib64/security/pam_elogind.so "$ROOTFS/usr/lib64/security/pam_systemd.so"
ln -sfn /usr/lib64/security/pam_elogind.so "$ROOTFS/lib64/security/pam_systemd.so"
ln -sfn /usr/lib64/security/pam_elogind.so "$ROOTFS/lib/x86_64-linux-gnu/security/pam_systemd.so"
ln -sfn /usr/lib64/security/pam_elogind.so "$ROOTFS/usr/lib/x86_64-linux-gnu/security/pam_systemd.so"

mkdir -p "$ROOTFS/usr/libexec/geminios"
cat > "$ROOTFS/usr/libexec/geminios/elogind-launch" <<'EOF'
#!/bin/sh
for candidate in \
    /usr/libexec/elogind \
    /usr/lib/elogind/elogind \
    /usr/libexec/elogind/elogind \
    /usr/lib64/elogind/elogind
do
    if [ -x "$candidate" ]; then
        exec "$candidate" "$@"
    fi
done

echo "E: elogind daemon not found in expected locations." >&2
exit 1
EOF
chmod 755 "$ROOTFS/usr/libexec/geminios/elogind-launch"

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
mkdir -p "$ROOTFS/usr/lib64"
gcc -shared -fPIC "$ROOT_DIR/build_system/gdk_wayland_compat.c" \
    -o "$ROOTFS/usr/lib64/libgdk-wayland-compat.so"

cat > "$ROOTFS/bin/startxfce4" <<'EOF'
#!/bin/sh
REAL_STARTXFCE4="/usr/bin/startxfce4"

if [ ! -x "$REAL_STARTXFCE4" ]; then
    echo "E: $REAL_STARTXFCE4 was not found." >&2
    exit 1
fi

export GDK_BACKEND="${GDK_BACKEND:-x11}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"

if [ -z "$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

if [ ! -f /usr/lib64/pkgconfig/gdk-wayland-3.0.pc ] && [ -r /usr/lib64/libgdk-wayland-compat.so ]; then
    export LD_PRELOAD="/usr/lib64/libgdk-wayland-compat.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- "$REAL_STARTXFCE4" "$@"
fi

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax)"
    export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
fi

exec "$REAL_STARTXFCE4" "$@"
EOF
chmod 755 "$ROOTFS/bin/startxfce4"

# Prepare runtime/session paths used by Wayland-capable applications.
mkdir -p "$ROOTFS/run/user"
chmod 755 "$ROOTFS/run/user"
mkdir -p "$ROOTFS/run/systemd" "$ROOTFS/run/systemd/inhibit" "$ROOTFS/run/systemd/seats"
mkdir -p "$ROOTFS/run/systemd/sessions" "$ROOTFS/run/systemd/users" "$ROOTFS/var/lib/elogind"
mkdir -p "$ROOTFS/usr/share/wayland-sessions"

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
    ModulePath "/usr/lib64/xorg/modules"
    ModulePath "/usr/lib64/dri"
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

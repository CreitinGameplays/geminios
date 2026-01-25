#!/bin/bash
set -e

echo "Installing Ginit Core..."
cd "$ROOT_DIR/ginit"
make install DESTDIR="$ROOTFS"
cd -

echo "Compiling Package Manager (gpkg)..."
g++ $CXXFLAGS -I"$ROOT_DIR/ginit/src" -I"$ROOT_DIR/src" -o gpkg "$ROOT_DIR/packages/system/gpkg/gpkg.cpp" -L"$ROOT_DIR/ginit/lib" -lgemcore -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip gpkg

# Additional setup for ginit
# ginit Makefile now installs binaries to /bin and /sbin
# and services to /usr/lib/ginit/services

# Ensure /init points to /bin/ginit (PID 1)
cp "$ROOTFS/bin/ginit" "$ROOTFS/init"
ln -sf ginit "$ROOTFS/bin/init"

ln -sf bash "$ROOTFS/bin/sh"
cp gpkg "$ROOTFS/bin/gpkg"

# Create default system files (passwd, group, shadow)
mkdir -p "$ROOTFS/etc"

# 1. /etc/passwd - Use /bin/bash as shell
cat > "$ROOTFS/etc/passwd" <<EOF
root:x:0:0:System Administrator:/root:/bin/bash
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
users:x:100:
input:x:101:
render:x:102:
sgx:x:103:
tape:x:26:
kvm:x:78:
messagebus:x:18:
EOF

# 3. /etc/shadow
cat > "$ROOTFS/etc/shadow" <<EOF
root:\$5\$GEMINI_SALT\$4813494d137e1631bba301d5acab6e7bb7aa74ce1185d456565ef51d737677b2:19000:0:99999:7:::
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

mkdir -p "$ROOTFS/etc/pam.d"

# Common PAM configuration
cat > "$ROOTFS/etc/pam.d/common-auth" <<EOF
auth    required    pam_unix.so nullok
EOF

cat > "$ROOTFS/etc/pam.d/common-account" <<EOF
account required    pam_unix.so
EOF

cat > "$ROOTFS/etc/pam.d/common-session" <<EOF
session required    pam_unix.so
EOF

cat > "$ROOTFS/etc/pam.d/common-password" <<EOF
password required   pam_unix.so nullok md5 shadow
EOF

# LightDM PAM configuration
cat > "$ROOTFS/etc/pam.d/lightdm" <<EOF
#%PAM-1.0
auth    include common-auth
account include common-account
password include common-password
session include common-session
EOF

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

cat > "$ROOTFS/etc/ld.so.conf" <<EOF
/lib64
/usr/lib64
/usr/local/lib64
/lib
/usr/lib
/usr/local/lib
include /etc/ld.so.conf.d/*.conf
EOF
mkdir -p "$ROOTFS/etc/ld.so.conf.d"

# Fix /var/run -> /run
rm -rf "$ROOTFS/var/run"
ln -sf /run "$ROOTFS/var/run"

# 5. Xorg Configuration
mkdir -p "$ROOTFS/etc/X11"
mkdir -p "$ROOTFS/var/lib/xkb"
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
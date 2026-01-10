#!/bin/bash
set -e

echo "Compiling Shared Signals..."
g++ -c "$ROOT_DIR/src/signals.cpp" -o "$ROOT_DIR/src/signals.o"

echo "Compiling User Management..."
g++ -c "$ROOT_DIR/src/user_mgmt.cpp" -o "$ROOT_DIR/src/user_mgmt.o" -lssl -lcrypto

echo "Compiling Init (Ginit)..."
g++ $CXXFLAGS -o ginit "$ROOT_DIR/src/ginit.cpp" "$ROOT_DIR/src/network.cpp" "$ROOT_DIR/src/signals.o" "$ROOT_DIR/src/user_mgmt.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip ginit

# Install ginit
cp ginit "$ROOTFS/ginit"
chmod +x "$ROOTFS/ginit"
cp ginit "$ROOTFS/bin/ginit"

# Create compatibility symlink for /bin/init
ln -sf ginit "$ROOTFS/bin/init"
# Optional: maintain /init as symlink if feasible, or just rely on kernel finding ginit if we update kernel cmdline?
# But typically kernel looks for /init. If we rename /init to /ginit on root, kernel fails unless we pass init=/ginit.
# Safer to keep /init as a symlink or copy to ginit.
cp ginit "$ROOTFS/init" # Keeping as copy at root for simplicity/robustness

# Create default system files (passwd, group, shadow)
mkdir -p "$ROOTFS/etc"

# 1. /etc/passwd
cat > "$ROOTFS/etc/passwd" <<EOF
root:x:0:0:System Administrator:/root:/bin/init
messagebus:x:18:18:D-Bus Message Daemon User:/var/run/dbus:/bin/false
EOF

# 2. /etc/group
cat > "$ROOTFS/etc/group" <<EOF
root:x:0:
sudo:x:27:root
users:x:100:
messagebus:x:18:
EOF

# 3. /etc/shadow
cat > "$ROOTFS/etc/shadow" <<EOF
root:\$5\$GEMINI_SALT\$4813494d137e1631bba301d5acab6e7bb7aa74ce1185d456565ef51d737677b2:19000:0:99999:7:::
EOF
chmod 600 "$ROOTFS/etc/shadow"

# 4. Xorg Configuration
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
EndSection

Section "Module"
    Load "fbdevhw"
    Load "glx"
    Load "dri"
    Load "dri2"
EndSection

Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AllowEmptyInput" "true"
    Option "AIGLX" "true"
EndSection

Section "InputClass"
    Identifier "keyboard"
    MatchIsKeyboard "on"
    Option "XkbRules" "evdev"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us"
EndSection

Section "Device"
    Identifier "Card0"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
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

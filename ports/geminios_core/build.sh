#!/bin/bash
set -e

echo "Compiling Shared Signals..."
g++ -c "$ROOT_DIR/src/signals.cpp" -o "$ROOT_DIR/src/signals.o"

echo "Compiling User Management..."
g++ -c "$ROOT_DIR/src/user_mgmt.cpp" -o "$ROOT_DIR/src/user_mgmt.o" -lssl -lcrypto

echo "Compiling Init (Ginit)..."
g++ $CXXFLAGS -o ginit "$ROOT_DIR/src/ginit.cpp" "$ROOT_DIR/src/network.cpp" "$ROOT_DIR/src/signals.o" "$ROOT_DIR/src/user_mgmt.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip ginit

echo "Compiling Shell (Gsh)..."
g++ $CXXFLAGS -o gsh "$ROOT_DIR/src/gsh.cpp" "$ROOT_DIR/src/signals.o" -lz -lzstd -ldl -lpthread
strip gsh

echo "Compiling Login..."
g++ $CXXFLAGS -o login "$ROOT_DIR/src/login.cpp" "$ROOT_DIR/src/user_mgmt.o" "$ROOT_DIR/src/signals.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip login

echo "Compiling Getty..."
g++ $CXXFLAGS -o getty "$ROOT_DIR/src/getty.cpp"
strip getty

echo "Compiling Package Manager (gpkg)..."
g++ $CXXFLAGS -o gpkg "$ROOT_DIR/packages/system/gpkg/gpkg.cpp" "$ROOT_DIR/src/network.cpp" "$ROOT_DIR/src/signals.o" -lssl -lcrypto -lz -lzstd -ldl -lpthread
strip gpkg

# Install binaries
mkdir -p "$ROOTFS/bin" "$ROOTFS/sbin"

cp ginit "$ROOTFS/bin/ginit"
cp ginit "$ROOTFS/init" # Keeping at root for robustness
ln -sf ginit "$ROOTFS/bin/init"

cp gsh "$ROOTFS/bin/gsh"
ln -sf gsh "$ROOTFS/bin/sh"

cp login "$ROOTFS/bin/login"
cp getty "$ROOTFS/sbin/getty"
cp gpkg "$ROOTFS/bin/gpkg"

# Create default system files (passwd, group, shadow)
mkdir -p "$ROOTFS/etc"

# 1. /etc/passwd - Use /bin/gsh as shell
cat > "$ROOTFS/etc/passwd" <<EOF
root:x:0:0:System Administrator:/root:/bin/gsh
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
rm -f ginit gsh login getty init gpkg gpkg-worker
#!/bin/bash
set -e

PKG_NAME="texinfo"
PKG_VER="7.1"
SRC_URL="https://ftp.gnu.org/gnu/texinfo/texinfo-$PKG_VER.tar.xz"
SRC_DIR="texinfo-$PKG_VER"

# Download and Extract
download_and_extract "$SRC_URL" "$SRC_DIR.tar.xz" "$SRC_DIR"

rm -rf build
mkdir -p build
cd build

# Create a HELP2MAN replacement that creates empty man pages
# (help2man runs binaries to extract --help output, which doesn't work well
#  in this build environment, and the default HELP2MAN=true produces no file,
#  causing 'mv' failures in man page rules)
cat > help2man-stub.sh << 'HELPEOF'
#!/bin/bash
# Parse the -o argument to find the output file
outfile=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) outfile="$2"; shift 2 ;;
        -o*) outfile="${1#-o}"; shift ;;
        *) shift ;;
    esac
done
if [ -n "$outfile" ]; then
    touch "$outfile"
fi
exit 0
HELPEOF
chmod +x help2man-stub.sh

# Configure
if [ ! -f "Makefile" ]; then
    "$DEP_DIR/$SRC_DIR/configure" \
        --prefix=/usr \
        --disable-nls \
        --disable-perl-xs \
        --with-sysroot="$ROOTFS" \
        MAKEINFO=true
fi

# Build
export PERL5LIB="$PWD/tp:$DEP_DIR/$SRC_DIR/tp:$DEP_DIR/$SRC_DIR/Pod-Simple-Texinfo/lib"
make -j$JOBS MAKEINFO=true HELP2MAN="$PWD/help2man-stub.sh"

# Install
export PERL5LIB="$PWD/tp:$DEP_DIR/$SRC_DIR/tp:$DEP_DIR/$SRC_DIR/Pod-Simple-Texinfo/lib"
make install DESTDIR="$ROOTFS" MAKEINFO=true HELP2MAN="$PWD/help2man-stub.sh"

# Cleanup
rm -rf "$ROOTFS/usr/share/info"
rm -rf "$ROOTFS/usr/share/man"

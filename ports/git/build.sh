#!/bin/bash
set -e

GIT_VER="2.45.2"
download_and_extract "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$GIT_VER.tar.xz" "git-$GIT_VER.tar.xz" "git-$GIT_VER"

cd "$DEP_DIR/git-$GIT_VER"

TOOLS_DIR="$DEP_DIR/git-build-tools"
mkdir -p "$TOOLS_DIR"

cat > "$TOOLS_DIR/curl-config" <<EOF
#!/bin/sh
set -e

ROOTFS="\${ROOTFS:?ROOTFS is not set}"

"$ROOTFS/usr/bin/curl-config" "\$@" | sed \
    -e "s#-I/usr/include##g" \
    -e "s#-L/usr/lib/x86_64-linux-gnu##g" \
    -e "s#-L/usr/lib64##g" \
    -e "s#-L/usr/lib##g" \
    -e "s#-L/lib/x86_64-linux-gnu##g" \
    -e "s#-L/lib64##g"
EOF
chmod +x "$TOOLS_DIR/curl-config"

export PATH="$TOOLS_DIR:$PATH"

if [ -f configure ]; then
    ./configure --prefix=/usr --libdir=/usr/lib/x86_64-linux-gnu --host=x86_64-linux-gnu
fi

make -j$JOBS \
    prefix=/usr \
    gitexecdir=/usr/libexec/git-core \
    CURL_CONFIG=curl-config \
    NO_PERL=YesPlease \
    NO_TCLTK=YesPlease \
    NO_GETTEXT=YesPlease \
    NO_INSTALL_HARDLINKS=YesPlease

make install DESTDIR="$ROOTFS" \
    prefix=/usr \
    gitexecdir=/usr/libexec/git-core \
    CURL_CONFIG=curl-config \
    NO_PERL=YesPlease \
    NO_TCLTK=YesPlease \
    NO_GETTEXT=YesPlease \
    NO_INSTALL_HARDLINKS=YesPlease

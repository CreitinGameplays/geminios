#!/bin/bash
set -e

PERL_VER="5.38.2"
download_and_extract "https://www.cpan.org/src/5.0/perl-$PERL_VER.tar.gz" "perl-$PERL_VER.tar.gz" "perl-$PERL_VER"

# Workaround for miniperl path issue:
# miniperl seems to strip 'external_dependencies' from the path when resolving @INC,
# expecting to find libraries in /path/to/geminios/perl-5.38.2 instead of external_dependencies/perl-5.38.2.
# We create a symlink in the root to satisfy this weird requirement.
ln -sf "$DEP_DIR/perl-$PERL_VER" "$ROOT_DIR/perl-$PERL_VER"

cd "$DEP_DIR/perl-$PERL_VER"
./Configure -des -Dprefix=/usr -Duseshrplib

# Patch makefile to use absolute path for -Ilib to fix "Can't locate strict.pm"
# This is required because miniperl sometimes gets confused with relative paths in this cross-ish environment
sed -i "s|-Ilib|-I$(pwd)/lib|g" makefile

make -j$JOBS
make install DESTDIR="$ROOTFS"

if [ -f "$ROOTFS/usr/lib/perl5/$PERL_VER/x86_64-linux/CORE/libperl.so" ]; then
    cp -v "$ROOTFS/usr/lib/perl5/$PERL_VER/x86_64-linux/CORE/libperl.so" "$ROOTFS/usr/lib/"
fi

# Cleanup symlink
rm -f "$ROOT_DIR/perl-$PERL_VER"
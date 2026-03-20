#!/bin/bash
set -e

VER="3.1.4"
SITE_PACKAGES="$ROOTFS/usr/lib64/python3.11/site-packages"
EGG_INFO="$SITE_PACKAGES/Jinja2-$VER-py3.11.egg-info"

download_and_extract \
    "https://files.pythonhosted.org/packages/source/j/jinja2/jinja2-$VER.tar.gz" \
    "jinja2-$VER.tar.gz" \
    "jinja2-$VER"
cd "$DEP_DIR/jinja2-$VER"

install -d "$SITE_PACKAGES"
rm -rf "$SITE_PACKAGES/jinja2" "$EGG_INFO"

# Jinja2 3.x ships as a pyproject-only pure Python package, so stage it directly.
cp -a src/jinja2 "$SITE_PACKAGES/jinja2"
find "$SITE_PACKAGES/jinja2" -type d -name "__pycache__" -prune -exec rm -rf {} +

install -d "$EGG_INFO"
install -m 644 PKG-INFO "$EGG_INFO/PKG-INFO"
: > "$EGG_INFO/dependency_links.txt"
printf 'MarkupSafe>=2.0\n\n[i18n]\nBabel>=2.7\n' > "$EGG_INFO/requires.txt"
printf 'jinja2\n' > "$EGG_INFO/top_level.txt"
{
    printf 'LICENSE.txt\n'
    printf 'PKG-INFO\n'
    printf 'pyproject.toml\n'
    find src/jinja2 -type f | LC_ALL=C sort
} > "$EGG_INFO/SOURCES.txt"

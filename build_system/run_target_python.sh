#!/bin/bash
# Wrapper to run the target (rootfs) python3

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
export ROOT_DIR="$(dirname "$DIR")"
export ROOTFS="$ROOT_DIR/rootfs"
export PYTHONHOME="$ROOTFS/usr"

# Explicitly invoke the dynamic loader from the rootfs
# This avoids using the host's loader which might be incompatible with the target's libc
LOADER="$ROOTFS/lib64/ld-linux-x86-64.so.2"
LIBRARY_PATH="$ROOTFS/usr/lib64:$ROOTFS/usr/lib:$ROOTFS/lib64"

if [ ! -x "$LOADER" ]; then
    echo "Error: Loader not found at $LOADER"
    exit 1
fi

exec "$LOADER" --library-path "$LIBRARY_PATH" "$ROOTFS/usr/bin/python3" "$@"

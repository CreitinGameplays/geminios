#!/bin/bash
# Wrapper to run the target (rootfs) python3
set -e

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
export ROOT_DIR="$(dirname "$DIR")"
export BOOTSTRAP_ROOTFS="$ROOT_DIR/bootstrap_rootfs"
export BUILD_SYSROOT="$ROOT_DIR/build_sysroot"
export FINAL_ROOTFS="$ROOT_DIR/rootfs"
export ROOTFS="${TARGET_SYSROOT:-$BUILD_SYSROOT}"
export PYTHONHOME="$ROOTFS/usr"
TARGET_MULTIARCH="${TARGET_MULTIARCH:-$(gcc -print-multiarch 2>/dev/null || true)}"
if [ -z "$TARGET_MULTIARCH" ]; then
  TARGET_MULTIARCH="x86_64-linux-gnu"
fi
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
PYTHON_BIN="$ROOTFS/usr/bin/python3"
PYTHON_LOADER="$ROOTFS/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"

LIBRARY_PATH="$ROOTFS/lib/x86_64-linux-gnu:$ROOTFS/usr/lib/x86_64-linux-gnu:$ROOTFS/lib64:$ROOTFS/usr/lib64"
export PYTHONNOUSERSITE=1
unset LD_LIBRARY_PATH

python_extra_paths=()
if [ -n "$TARGET_MULTIARCH" ]; then
    python_extra_paths+=("$ROOTFS/usr/lib/$TARGET_MULTIARCH/python$PYTHON_VERSION/lib-dynload")
    python_extra_paths+=("$ROOTFS/usr/lib/$TARGET_MULTIARCH/python$PYTHON_VERSION/site-packages")
fi
python_extra_paths+=("$ROOTFS/usr/lib/python$PYTHON_VERSION/site-packages")

PYTHONPATH_PREFIX=""
for candidate in "${python_extra_paths[@]}"; do
    if [ -d "$candidate" ]; then
        if [ -n "$PYTHONPATH_PREFIX" ]; then
            PYTHONPATH_PREFIX="$PYTHONPATH_PREFIX:$candidate"
        else
            PYTHONPATH_PREFIX="$candidate"
        fi
    fi
done

if [ -n "$PYTHONPATH_PREFIX" ]; then
    export PYTHONPATH="$PYTHONPATH_PREFIX${PYTHONPATH:+:$PYTHONPATH}"
fi

if [ ! -x "$PYTHON_BIN" ]; then
    echo "Error: Python not found at $PYTHON_BIN"
    exit 1
fi

if [ ! -x "$PYTHON_LOADER" ]; then
    echo "Error: staged loader not found at $PYTHON_LOADER"
    exit 1
fi

exec "$PYTHON_LOADER" --library-path "$LIBRARY_PATH" "$PYTHON_BIN" "$@"

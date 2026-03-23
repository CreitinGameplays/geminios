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
TARGET_MULTIARCH="${TARGET_MULTIARCH:-$(gcc -print-multiarch 2>/dev/null || true)}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"

# Use the host loader but force the staged GeminiOS runtime libraries first.
# The target loader has proven brittle for build-time Python execution in the
# host environment, while the host loader works correctly with the staged
# libpython/glibc set as long as the rootfs library paths are first.
LIBRARY_PATH="$ROOTFS/usr/lib/x86_64-linux-gnu:$ROOTFS/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$LIBRARY_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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

if [ ! -x "$ROOTFS/usr/bin/python3" ]; then
    echo "Error: Python not found at $ROOTFS/usr/bin/python3"
    exit 1
fi

exec "$ROOTFS/usr/bin/python3" "$@"

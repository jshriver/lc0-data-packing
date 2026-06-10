#!/bin/bash

set -e

CURRENT_PID=""
STOP_REQUESTED=0

run_interruptible() {
    "$@" &
    CURRENT_PID=$!

    local status=0
    if ! wait "$CURRENT_PID"; then
        status=$?
    fi
    CURRENT_PID=""
    return "$status"
}

handle_signal() {
    STOP_REQUESTED=1
    if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        kill "$CURRENT_PID" 2>/dev/null || true
        wait "$CURRENT_PID" 2>/dev/null || true
        CURRENT_PID=""
    fi
}

trap 'handle_signal' INT TERM

BASE_URL="https://data.lczero.org/files/training_data/test91/"
DATA_DIR="./data"
BINPACK_DIR="./binpacks"
SYZYGY_PATH=$1
RESCORER_BIN="./lc0/build/release/rescorer"

if [ -z "$SYZYGY_PATH" ]; then
    echo "Usage: $0 <SYZYGY_PATH>"
    exit 1
fi

mkdir -p "$DATA_DIR"
mkdir -p "$BINPACK_DIR"

echo "Fetching list of tarballs from $BASE_URL..."
TARBALLS=$(curl -s "$BASE_URL" \
    | grep -oE 'href="[^"]+\.tar"' \
    | sed -E 's/href="([^"]+)"/\1/' \
    | sort -r)

if [ -z "$TARBALLS" ]; then
    echo "No tarballs found at $BASE_URL"
    exit 1
fi

for TARBALL in $TARBALLS; do
    if [ "$STOP_REQUESTED" -ne 0 ]; then
        echo "Interrupted, stopping..."
        exit 130
    fi

    echo "============================================="
    echo "Processing $TARBALL..."

    NAME="${TARBALL%.tar}"
    TAR_PATH="${DATA_DIR}/${TARBALL}"
    EXTRACT_PATH="${DATA_DIR}/${NAME}"
    BINPACK_PATH="${BINPACK_DIR}/${NAME}.binpack"
    DONE_FLAG="${BINPACK_DIR}/${NAME}.done"

    # Full success check
    if [ -f "$BINPACK_PATH" ] || [ -f "$DONE_FLAG" ]; then
        echo "Already processed, skipping..."
        continue
    fi

    # Download only if missing
    if [ ! -f "$TAR_PATH" ]; then
        echo "Downloading ${TARBALL}..."
        run_interruptible wget -c "${BASE_URL}${TARBALL}" -O "$TAR_PATH"
    else
        echo "Tar already exists, skipping download..."
    fi

    # Extract only if missing
    if [ ! -d "$EXTRACT_PATH" ]; then
        echo "Extracting ${TARBALL}..."
        run_interruptible tar -xf "$TAR_PATH" -C "$DATA_DIR"
    else
        echo "Already extracted, skipping..."
    fi

    echo "Running rescorer..."
    run_interruptible "$RESCORER_BIN" rescore \
        --syzygy-paths="$SYZYGY_PATH" \
        --input="$EXTRACT_PATH" \
        --binpack-file="$BINPACK_PATH" \
        --nnue-best-score=true \
        --nnue-best-move=true \
        --deblunder=true \
        --deblunder-q-blunder-threshold=0.10 \
        --deblunder-q-blunder-width=0.03 \
        --threads=5 \
        --delete-files

    # Mark success explicitly
    touch "$DONE_FLAG"

    echo "Cleaning up..."
    rm -f "$TAR_PATH"
    rm -rf "$EXTRACT_PATH"

    echo "Finished processing $TARBALL"
done

echo "All done!"

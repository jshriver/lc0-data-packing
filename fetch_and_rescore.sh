#!/bin/bash

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

BASE_URL="https://data.lczero.org/files/training_data/test91/"
DATA_DIR="./data"
BINPACK_DIR="./binpacks"
RESCORER_BIN="./lc0/build/release/rescorer"

###############################################################################
# Runtime State
###############################################################################

CURRENT_PID=""
STOP_REQUESTED=0

###############################################################################
# Utility Functions
###############################################################################

banner() {
    echo
    echo "═══════════════════════════════════════════════"
    echo "$1"
    echo "═══════════════════════════════════════════════"
}

usage() {
    cat <<EOF

Usage:
  $0 --syzygy <PATH> [--from FILE] [--to FILE]

Examples:

  Process everything:
    $0 --syzygy /tb

  Process a range:
    $0 --syzygy /tb \\
       --from training-run2-test91-20251130-2317.tar \\
       --to   training-run2-test91-20251120-0017.tar

  Process from a point onward:
    $0 --syzygy /tb \\
       --from training-run2-test91-20251120-0017.tar

EOF
}

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

    echo
    echo "🛑 Interrupt received"

    if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
        echo "⚡ Stopping active process..."
        kill "$CURRENT_PID" 2>/dev/null || true
        wait "$CURRENT_PID" 2>/dev/null || true
        CURRENT_PID=""
    fi
}

trap 'handle_signal' INT TERM

###############################################################################
# Argument Parsing
###############################################################################

SYZYGY_PATH=""
FROM_FILE=""
TO_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --syzygy)
            SYZYGY_PATH="$2"
            shift 2
            ;;
        --from)
            FROM_FILE="$2"
            shift 2
            ;;
        --to)
            TO_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$SYZYGY_PATH" ]; then
    echo "❌ Missing required argument: --syzygy"
    usage
    exit 1
fi

###############################################################################
# Setup
###############################################################################

mkdir -p "$DATA_DIR"
mkdir -p "$BINPACK_DIR"

###############################################################################
# Fetch Tarball List
###############################################################################

banner "🌐 Fetching Test91 tarball list"

TARBALLS=$(
    curl -s "$BASE_URL" \
    | grep -oE 'href="[^"]+\.tar"' \
    | sed -E 's/href="([^"]+)"/\1/' \
    | sort -r
)

if [ -z "$TARBALLS" ]; then
    echo "❌ No tarballs found."
    exit 1
fi

###############################################################################
# Validate Range Boundaries
###############################################################################

if [ -n "$FROM_FILE" ]; then
    if ! echo "$TARBALLS" | grep -Fxq "$FROM_FILE"; then
        echo "❌ --from file not found:"
        echo "   $FROM_FILE"
        exit 1
    fi
fi

if [ -n "$TO_FILE" ]; then
    if ! echo "$TARBALLS" | grep -Fxq "$TO_FILE"; then
        echo "❌ --to file not found:"
        echo "   $TO_FILE"
        exit 1
    fi
fi

###############################################################################
# Range Filtering
###############################################################################

FILTERED_TARBALLS=""
IN_RANGE=0

while IFS= read -r TARBALL; do

    if [ -n "$FROM_FILE" ]; then

        if [ "$IN_RANGE" -eq 0 ]; then
            if [ "$TARBALL" = "$FROM_FILE" ]; then
                IN_RANGE=1
            else
                continue
            fi
        fi

    else
        IN_RANGE=1
    fi

    FILTERED_TARBALLS+="$TARBALL"$'\n'

    if [ -n "$TO_FILE" ] && [ "$TARBALL" = "$TO_FILE" ]; then
        break
    fi

done <<< "$TARBALLS"

TARBALLS="$FILTERED_TARBALLS"

COUNT=$(echo "$TARBALLS" | grep -c '\.tar$' || true)

banner "📋 Processing Summary"

echo "📦 Tarballs selected : $COUNT"

[ -n "$FROM_FILE" ] && echo "📍 From              : $FROM_FILE"
[ -n "$TO_FILE" ]   && echo "🏁 To                : $TO_FILE"

if [ "$COUNT" -eq 0 ]; then
    echo
    echo "❌ Selected range contains no tarballs."
    exit 1
fi

###############################################################################
# Main Processing Loop
###############################################################################

for TARBALL in $TARBALLS; do

    if [ "$STOP_REQUESTED" -ne 0 ]; then
        echo
        echo "🛑 Stopping due to interrupt."
        exit 130
    fi

    NAME="${TARBALL%.tar}"

    TAR_PATH="${DATA_DIR}/${TARBALL}"
    EXTRACT_PATH="${DATA_DIR}/${NAME}"

    BINPACK_PATH="${BINPACK_DIR}/${NAME}.binpack"
    DONE_FLAG="${BINPACK_DIR}/${NAME}.done"

    banner "🚂 Processing $TARBALL"

    ###########################################################################
    # Skip completed work
    ###########################################################################

    if [ -f "$DONE_FLAG" ]; then
        echo "⏭️  Already processed, skipping."
        continue
    fi

    ###########################################################################
    # Download
    ###########################################################################

    if [ ! -f "$TAR_PATH" ]; then
        echo "⬇️  Downloading..."
        run_interruptible wget -c "${BASE_URL}${TARBALL}" -O "$TAR_PATH"
    else
        echo "📥 Tar already exists."
    fi

    ###########################################################################
    # Extract
    ###########################################################################

    if [ ! -d "$EXTRACT_PATH" ]; then
        echo "📦 Extracting..."
        run_interruptible tar -xf "$TAR_PATH" -C "$DATA_DIR"
    else
        echo "📂 Already extracted."
    fi

    ###########################################################################
    # Rescore
    ###########################################################################

    echo "🧠 Running rescorer..."

    run_interruptible \
        "$RESCORER_BIN" rescore \
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

    ###########################################################################
    # Mark Success
    ###########################################################################

    touch "$DONE_FLAG"

    ###########################################################################
    # Cleanup
    ###########################################################################

    echo "🧹 Cleaning up..."

    rm -f "$TAR_PATH"
    rm -rf "$EXTRACT_PATH"

    echo "✅ Finished $TARBALL"
done

###############################################################################
# Finished
###############################################################################

banner "🎉🎉🎉 ALL DONE! 🎉🎉🎉"

echo "🧠 Rescoring complete"
echo "📦 Binpacks generated"
echo "🧹 Workspace cleaned"

echo
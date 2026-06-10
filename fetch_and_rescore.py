#!/usr/bin/env python3

import argparse
import re
import shutil
import signal
import subprocess
import sys
import textwrap
from pathlib import Path

import requests
from bs4 import BeautifulSoup

###############################################################################
# Configuration
###############################################################################

BASE_URL     = "https://data.lczero.org/files/training_data/test91/"
DATA_DIR     = Path("./data")
BINPACK_DIR  = Path("./binpacks")
RESCORER_BIN = Path("./lc0/build/release/rescorer")

HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; lc0-fetcher/1.0)"}

###############################################################################
# Globals
###############################################################################

current_proc: subprocess.Popen | None = None
stop_requested = False

###############################################################################
# Signal handling
###############################################################################

def handle_signal(signum, frame):
    global stop_requested, current_proc
    stop_requested = True
    print("\n🛑 Interrupt received")
    if current_proc and current_proc.poll() is None:
        print("⚡ Stopping active process...")
        current_proc.terminate()
        try:
            current_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            current_proc.kill()
        current_proc = None

signal.signal(signal.SIGINT,  handle_signal)
signal.signal(signal.SIGTERM, handle_signal)

###############################################################################
# Helpers
###############################################################################

def banner(msg: str):
    line = "═" * 47
    print(f"\n{line}\n{msg}\n{line}")


def run(cmd: list[str]) -> int:
    global current_proc
    current_proc = subprocess.Popen(cmd)
    ret = current_proc.wait()
    current_proc = None
    return ret


###############################################################################
# Argument parsing
###############################################################################

parser = argparse.ArgumentParser(
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description="Download and rescore lc0 Test91 training data.",
    epilog=textwrap.dedent("""
        Examples:
          Process everything:
            %(prog)s --syzygy /tb

          Process a range (--from is the older date, --to is the newer date):
            %(prog)s --syzygy /tb \\
                --from training-run2-test91-20251120-0017.tar \\
                --to   training-run2-test91-20251130-2317.tar

          Process from a point onward:
            %(prog)s --syzygy /tb \\
                --from training-run2-test91-20251120-0017.tar
    """),
)
parser.add_argument("--syzygy", required=True, metavar="PATH",
                    help="Path to Syzygy tablebases")
parser.add_argument("--from",   dest="from_file", metavar="FILE",
                    help="Start tarball (inclusive)")
parser.add_argument("--to",     dest="to_file",   metavar="FILE",
                    help="End tarball (inclusive)")
args = parser.parse_args()

###############################################################################
# Setup
###############################################################################

DATA_DIR.mkdir(parents=True, exist_ok=True)
BINPACK_DIR.mkdir(parents=True, exist_ok=True)

###############################################################################
# Fetch tarball list
###############################################################################

banner("🌐 Fetching Test91 tarball list")

resp = requests.get(BASE_URL, headers=HEADERS, timeout=30)
resp.raise_for_status()

soup = BeautifulSoup(resp.text, "html.parser")
tarballs = sorted(
    (a["href"] for a in soup.find_all("a", href=re.compile(r"\.tar$")))
)

if not tarballs:
    print("❌ No tarballs found.")
    sys.exit(1)

###############################################################################
# Validate range boundaries
###############################################################################

if args.from_file and args.from_file not in tarballs:
    print(f"❌ --from file not found:\n   {args.from_file}")
    sys.exit(1)

if args.to_file and args.to_file not in tarballs:
    print(f"❌ --to file not found:\n   {args.to_file}")
    sys.exit(1)

###############################################################################
# Range filtering
###############################################################################

if args.from_file or args.to_file:
    start = tarballs.index(args.from_file) if args.from_file else 0
    end   = tarballs.index(args.to_file)   if args.to_file   else len(tarballs) - 1
    tarballs = tarballs[start:end + 1]

###############################################################################
# Summary
###############################################################################

banner("📋 Processing Summary")
print(f"📦 Tarballs selected : {len(tarballs)}")
if args.from_file:
    print(f"📍 From              : {args.from_file}")
if args.to_file:
    print(f"🏁 To                : {args.to_file}")

if not tarballs:
    print("\n❌ Selected range contains no tarballs.")
    sys.exit(1)

###############################################################################
# Main loop
###############################################################################

for tarball in tarballs:

    if stop_requested:
        print("\n🛑 Stopping due to interrupt.")
        sys.exit(130)

    name         = tarball.removesuffix(".tar")
    tar_path     = DATA_DIR / tarball
    extract_path = DATA_DIR / name
    binpack_path = BINPACK_DIR / f"{name}.binpack"
    done_flag    = BINPACK_DIR / f"{name}.done"

    banner(f"🚂 Processing {tarball}")

    # Skip
    if done_flag.exists():
        print("⏭️  Already processed, skipping.")
        continue

    # Download
    if not tar_path.exists():
        print("⬇️  Downloading...")
        ret = run(["wget", "-c", f"{BASE_URL}{tarball}", "-O", str(tar_path)])
        if ret != 0:
            print(f"❌ Download failed (exit {ret})")
            sys.exit(ret)
    else:
        print("📥 Tar already exists.")

    # Extract
    if not extract_path.exists():
        print("📦 Extracting...")
        ret = run(["tar", "-xf", str(tar_path), "-C", str(DATA_DIR)])
        if ret != 0:
            print(f"❌ Extraction failed (exit {ret})")
            sys.exit(ret)
    else:
        print("📂 Already extracted.")

    # Rescore
    print("🧠 Running rescorer...")
    ret = run([
        str(RESCORER_BIN), "rescore",
        f"--syzygy-paths={args.syzygy}",
        f"--input={extract_path}",
        f"--binpack-file={binpack_path}",
        "--nnue-best-score=true",
        "--nnue-best-move=true",
        "--deblunder=true",
        "--deblunder-q-blunder-threshold=0.10",
        "--deblunder-q-blunder-width=0.03",
        "--threads=5",
        "--delete-files",
    ])
    if ret != 0:
        print(f"❌ Rescorer failed (exit {ret})")
        sys.exit(ret)

    # Mark done
    done_flag.touch()

    # Cleanup
    print("🧹 Cleaning up...")
    tar_path.unlink(missing_ok=True)
    shutil.rmtree(extract_path, ignore_errors=True)

    print(f"✅ Finished {tarball}")

###############################################################################
# Done
###############################################################################

banner("🎉🎉🎉 ALL DONE! 🎉🎉🎉")
print("🧠 Rescoring complete")
print("📦 Binpacks generated")
print("🧹 Workspace cleaned\n")
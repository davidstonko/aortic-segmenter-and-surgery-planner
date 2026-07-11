#!/usr/bin/env bash
# aortic-centerline-cli — thin wrapper that invokes run_planner_headless.m
# on a DICOM directory and writes results to an output directory. Useful
# for shell scripts, cron jobs, or anyone who doesn't want to open the
# MATLAB IDE just to run one case.
#
# Usage:
#   aortic-centerline-cli <DICOM_DIR> [--out <OUT_DIR>] [--no-fast]
#                                     [--force-recache]
#
# Examples:
#   aortic-centerline-cli "/data/CT/JohnDoe1"
#   aortic-centerline-cli "/data/CT/JohnDoe1" --out results/JohnDoe1-run-1
#
# RESEARCH USE ONLY. Outputs are NOT a medical-device decision.
#
# Project: AINN/EVAR (Phase 3)
# Author:  David P. Stonko

set -euo pipefail

print_usage() {
    cat <<EOF
Usage:
  aortic-centerline-cli <DICOM_DIR> [options]

Options:
  --out <DIR>        Output directory (default: results/logs/cli_<timestamp>/)
  --no-fast          Disable TotalSegmentator --fast mode (slower but more accurate)
  --force-recache    Bypass the branch-detection disk cache (re-run from scratch)
  -h, --help         Show this help

The CLI runs run_planner_headless.m and prints the path of the saved
planner_result.mat + plan.txt + plan.json on success.

RESEARCH USE ONLY.
EOF
}

if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
fi

DICOM_DIR=""
OUT_DIR=""
FAST=true
FORCE_RECACHE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --no-fast)
            FAST=false
            shift
            ;;
        --force-recache)
            FORCE_RECACHE=true
            shift
            ;;
        --*)
            echo "Unknown option: $1" >&2
            print_usage
            exit 1
            ;;
        *)
            if [[ -z "$DICOM_DIR" ]]; then
                DICOM_DIR="$1"
            else
                echo "Unexpected argument: $1" >&2
                print_usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$DICOM_DIR" ]]; then
    echo "Error: DICOM_DIR required." >&2
    print_usage
    exit 1
fi

if [[ ! -d "$DICOM_DIR" ]]; then
    echo "Error: DICOM directory not found: $DICOM_DIR" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve MATLAB binary
MATLAB_BIN="${MATLAB:-matlab}"
if ! command -v "$MATLAB_BIN" >/dev/null 2>&1; then
    echo "Error: MATLAB not on PATH and \$MATLAB not set." >&2
    echo "Set MATLAB=/path/to/matlab and re-run." >&2
    exit 1
fi

# Build the opts struct as a one-liner
OPTS="struct('fast', $FAST"
if [[ "$FORCE_RECACHE" == "true" ]]; then
    OPTS="$OPTS, 'force_recache', true"
fi
if [[ -n "$OUT_DIR" ]]; then
    OPTS="$OPTS, 'out_dir', '$OUT_DIR'"
fi
OPTS="$OPTS)"

# Compose the MATLAB command. We change to the project root so the
# +autoseg, +reference, etc. packages resolve.
MCMD="try; \
    cd('$PROJECT_ROOT'); \
    addpath('scripts'); \
    out = run_planner_headless('$DICOM_DIR', $OPTS); \
    fprintf('OUT_DIR=%s\\n', out.out_dir); \
    exit(0); \
catch ME; \
    fprintf(2, 'ERROR: %s\\n', ME.message); \
    exit(2); \
end"

echo "Running planner on: $DICOM_DIR"
echo "MATLAB: $MATLAB_BIN"
echo ""
"$MATLAB_BIN" -batch "$MCMD"

#!/usr/bin/env bash
# install_external_tools.sh
#
# Sets up the two conda environments the EVAR Planner relies on:
#   - evar-tools  → TotalSegmentator CLI (auto-segmentation, Step 2)
#   - vmtk        → VMTK CLIs (centerlines, Step 4)
#
# Both are optional — the GUI has manual fallbacks. Install whichever
# you want.
#
# Usage:
#   bash scripts/install_external_tools.sh           # install both
#   bash scripts/install_external_tools.sh ts        # TotalSegmentator only
#   bash scripts/install_external_tools.sh vmtk      # VMTK only
#
# After install, activate the env you want BEFORE launching MATLAB so
# that the CLIs are on PATH for the system() calls the GUI makes.

set -euo pipefail

# Resolve the repo root so this script works regardless of cwd.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$REPO_ROOT"

if ! command -v conda &> /dev/null; then
    cat <<EOF >&2
Error: 'conda' is not on your PATH.

Install miniforge first (one-liner for macOS Apple Silicon):

  curl -L -O https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-arm64.sh
  bash Miniforge3-MacOSX-arm64.sh -b -p "\$HOME/miniforge3"
  "\$HOME/miniforge3/bin/conda" init "\$(basename "\$SHELL")"
  exec "\$SHELL"

Then re-run this script. (Use Miniforge3-MacOSX-x86_64.sh on Intel Macs.)
EOF
    exit 1
fi

WHICH="${1:-both}"

install_ts() {
    echo "==> Creating conda env 'evar-tools' (TotalSegmentator)…"
    conda env create -f environment.yml || \
        conda env update -f environment.yml --prune
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate evar-tools
    echo "==> Verifying TotalSegmentator…"
    TotalSegmentator -v
    conda deactivate
}

install_vmtk() {
    echo "==> Creating conda env 'vmtk' (VMTK)…"
    conda env create -f environment-vmtk.yml || \
        conda env update -f environment-vmtk.yml --prune
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate vmtk
    echo "==> Verifying VMTK CLIs…"
    which vmtkcenterlines
    which vmtkmarchingcubes
    conda deactivate
}

case "$WHICH" in
    ts|totalsegmentator)
        install_ts ;;
    vmtk)
        install_vmtk ;;
    both|"")
        install_ts
        install_vmtk ;;
    *)
        echo "Unknown selector: $WHICH (use ts | vmtk | both)" >&2
        exit 2 ;;
esac

cat <<EOF

==> Done.

Next step — activate ONE of the envs before launching MATLAB so the
relevant CLI is on PATH for system() calls:

    conda activate evar-tools && open -a MATLAB
    # or
    conda activate vmtk        && open -a MATLAB

Inside MATLAB, run:

    setup.check_dependencies

…to confirm the GUI sees the tools.

EOF

#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh

# https://github.com/nunchaku-tech/nunchaku
nunchaku_version="v1.2.1"

# Detect the compute capability of the GPUs present and compile only for those SMs.
export NUNCHAKU_INSTALL_MODE=FAST

# --- CONFIGURATION ---
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
# Limit concurrent extension builds. Eight avoids excessive memory use on hosts
# with many CPUs; override this after validating the available RAM.
default_max_jobs=$(nproc --all)
if [ "$default_max_jobs" -gt 8 ]; then default_max_jobs=8; fi
NUNCHAKU_MAX_JOBS="${NUNCHAKU_MAX_JOBS:-$default_max_jobs}"
# Usually leave unset: Nunchaku selects one NVCC thread per FAST-mode SM target.
NUNCHAKU_NVCC_THREADS="${NUNCHAKU_NVCC_THREADS:-}"
# ---------------------

# --- COLOR CODES (for console)---
LOG_ERR=$(printf '\033[0;41m') # White on RED BG
LOG_WARN=$(printf '\033[0;33m') # Yellow
LOG_OK=$(printf '\033[0;32m') # GREEN
LOG_INFO=$(printf '\033[0m') # No Color
NC=$(printf '\033[0m') # No Color
# --------------------------------

set -e

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo "$*"
  echo "!! Exiting nunchaku script (ID: $$)"
  exit 1
}

nunchaku_is_importable() {
  python -c 'import nunchaku; import nunchaku._C' > /dev/null 2>&1
}

patch_cutlass_for_cuda_13_3() {
  local source_dir=$1
  local matrix_header

  # CUDA 13.3 diagnoses stale calls in the CUTLASS revision pinned by Nunchaku
  # v1.2.1. The declared method, and the spelling used by current CUTLASS, is
  # set_slice_3x3.
  for matrix_header in \
    "$source_dir/third_party/cutlass/include/cutlass/matrix.h" \
    "$source_dir/third_party/Block-Sparse-Attention/csrc/cutlass/include/cutlass/matrix.h"
  do
    if [ ! -f "$matrix_header" ]; then
      error_exit "CUTLASS matrix header not found: $matrix_header"
    fi

    if grep -q '\.set_slice3x3(' "$matrix_header"; then
      echo "Patching obsolete CUTLASS set_slice3x3 calls in $matrix_header"
      sed -i 's/\.set_slice3x3(/.set_slice_3x3(/g' "$matrix_header"
    fi

    if grep -q '\.set_slice3x3(' "$matrix_header"; then
      error_exit "Failed to patch CUTLASS matrix header: $matrix_header"
    fi
  done
}

install_nunchaku() {
  local source_dir=$1
  local build_cmd="$source_dir/build.cmd"
  local build_log="$source_dir/build.log"

  {
    echo '#!/bin/bash'
    echo 'set -e'
    printf 'export EXT_PARALLEL=%q\n' "$NUNCHAKU_MAX_JOBS"
    printf 'export MAX_JOBS=%q\n' "$NUNCHAKU_MAX_JOBS"
    if [ -n "$NUNCHAKU_NVCC_THREADS" ]; then
      printf 'export NVCC_APPEND_FLAGS=%q\n' "--threads $NUNCHAKU_NVCC_THREADS"
    else
      echo 'unset NVCC_APPEND_FLAGS'
    fi
    printf 'cd %q\n' "$source_dir"
    printf '%s -e . --no-build-isolation\n' "$PIP3_CMD"
  } > "$build_cmd"
  chmod +x "$build_cmd"

  echo "CMD: \"$(tail -n 1 "$build_cmd")\""
  script -a -e -c "$build_cmd" "$build_log"
}

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

if [ "$FORCE_REINSTALL" = "false" ] && pip show nunchaku > /dev/null 2>&1; then
  if nunchaku_is_importable; then
    echo "${LOG_INFO}INFO:${NC} Nunchaku is already installed and importable."
    echo "     (Set FORCE_REINSTALL=true to force rebuild/reinstall)"
    exit 0
  fi
  echo "${LOG_WARN}WARNING:${NC} Nunchaku metadata exists, but its native module is not importable."
elif [ "$FORCE_REINSTALL" = "true" ]; then
  echo "${LOG_INFO}INFO:${NC} FORCE_REINSTALL is true. Proceeding..."
fi

echo "** Installing nunchaku **"

if ! command -v nvcc > /dev/null 2>&1; then
  error_exit "nvcc not found, canceling run"
fi
if ! pip3 show setuptools > /dev/null 2>&1; then
  error_exit "setuptools not installed, canceling run"
fi
if ! pip3 show ninja > /dev/null 2>&1; then
  error_exit "ninja not installed, canceling run"
fi
if [ -z "${PIP3_CMD:-}" ]; then
  error_exit "PIP3_CMD is not set"
fi
if ! [[ "$NUNCHAKU_MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  error_exit "NUNCHAKU_MAX_JOBS must be a positive integer"
fi
if [ -n "$NUNCHAKU_NVCC_THREADS" ] && ! [[ "$NUNCHAKU_NVCC_THREADS" =~ ^[1-9][0-9]*$ ]]; then
  error_exit "NUNCHAKU_NVCC_THREADS must be a positive integer when set"
fi

build_base_file="/comfy/mnt/venv/.build_base.txt"
if [ ! -s "$build_base_file" ]; then
  error_exit "$build_base_file not found or empty"
fi
BUILD_BASE=$(cat "$build_base_file")

torch_version=$(python - <<'PY'
import torch
print(".".join(torch.__version__.split("+")[0].split(".")[:2]))
PY
) || error_exit "torch not installed, canceling run"
if [ -z "$torch_version" ]; then
  error_exit "error getting torch version, canceling run"
fi

build_root="/comfy/mnt/src/${BUILD_BASE}/Torch_${torch_version}"
source_dir="$build_root/nunchaku-${nunchaku_version}"
mkdir -p "$build_root"

echo "PIP3_CMD: \"${PIP3_CMD}\""
echo " - numproc: $(nproc --all)"
echo " - max_jobs: $NUNCHAKU_MAX_JOBS"
if [ -n "$NUNCHAKU_NVCC_THREADS" ]; then
  echo " - nvcc_threads override: $NUNCHAKU_NVCC_THREADS"
else
  echo " - nvcc_threads: Nunchaku default"
fi

# Reuse a previous source checkout to repair an interrupted or stale editable
# installation. Because the source already has a BUILD_BASE/Torch-specific path,
# it is suitable for the current environment.
if [ -d "$source_dir" ] && [ "$FORCE_REINSTALL" = "false" ]; then
  echo "${LOG_INFO}INFO:${NC} Reinstalling Nunchaku from existing source: $source_dir"
  patch_cutlass_for_cuda_13_3 "$source_dir"
  install_nunchaku "$source_dir" || error_exit "Failed to build Nunchaku"
  nunchaku_is_importable || error_exit "Nunchaku installed but its native module is not importable"
  echo "${LOG_OK}SUCCESS:${NC} Nunchaku installed successfully"
  exit 0
fi

# Clone and patch in a temporary path, then promote it before installation.
# Editable-install metadata therefore records the stable final path rather than
# a timestamped directory that is moved after pip exits.
temporary_dir="${source_dir}-$(date +%Y%m%d%H%M%S)"
backup_dir=""

git clone \
  --branch "$nunchaku_version" \
  --recurse-submodules \
  https://github.com/nunchaku-tech/nunchaku.git \
  "$temporary_dir" || error_exit "Failed to clone Nunchaku"
patch_cutlass_for_cuda_13_3 "$temporary_dir"

if [ -d "$source_dir" ]; then
  backup_dir="${source_dir}.backup.$$"
  mv "$source_dir" "$backup_dir" || error_exit "Failed to preserve existing Nunchaku source"
fi

if ! mv "$temporary_dir" "$source_dir"; then
  if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    mv "$backup_dir" "$source_dir"
  fi
  error_exit "Failed to promote Nunchaku source to $source_dir"
fi

if ! install_nunchaku "$source_dir" || ! nunchaku_is_importable; then
  if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    failed_dir="${temporary_dir}.failed"
    mv "$source_dir" "$failed_dir"
    mv "$backup_dir" "$source_dir"
    error_exit "Failed to build Nunchaku; previous source restored and failed source kept at $failed_dir"
  fi
  error_exit "Failed to build or import Nunchaku; failed source kept at $source_dir"
fi

if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
  rm -rf "$backup_dir"
fi

echo "${LOG_OK}SUCCESS:${NC} Nunchaku built successfully"
exit 0

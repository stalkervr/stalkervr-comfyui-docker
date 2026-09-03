#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidia-dev.sh

# https://github.com/nunchaku-tech/nunchaku
nunchaku_version="v1.2.1"

# Detect the compute capability of the GPUs present and compile only for those SMs.
export NUNCHAKU_INSTALL_MODE=FAST

# --- CONFIGURATION ---
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"

# Limit concurrent extension builds.
default_max_jobs=$(nproc --all)
if [ "$default_max_jobs" -gt 8 ]; then
  default_max_jobs=8
fi
NUNCHAKU_MAX_JOBS="${NUNCHAKU_MAX_JOBS:-$default_max_jobs}"

# Usually leave unset: Nunchaku selects one NVCC thread per FAST-mode SM target.
NUNCHAKU_NVCC_THREADS="${NUNCHAKU_NVCC_THREADS:-}"

# Number of attempts for git submodule downloads.
NUNCHAKU_GIT_RETRIES="${NUNCHAKU_GIT_RETRIES:-5}"

# Delay between failed submodule attempts.
NUNCHAKU_GIT_RETRY_DELAY="${NUNCHAKU_GIT_RETRY_DELAY:-5}"
# ---------------------

# --- COLOR CODES ---
LOG_ERR=$(printf '\033[0;41m')
LOG_WARN=$(printf '\033[0;33m')
LOG_OK=$(printf '\033[0;32m')
LOG_INFO=$(printf '\033[0m')
NC=$(printf '\033[0m')
# -------------------

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

update_submodules_with_retry() {
  local source_dir=$1
  local attempt

  for attempt in $(seq 1 "$NUNCHAKU_GIT_RETRIES"); do
    echo
    echo "============================================================"
    echo "Updating Nunchaku submodules (attempt $attempt/$NUNCHAKU_GIT_RETRIES)"
    echo "============================================================"

    if ! git -C "$source_dir" \
      -c safe.directory="*" \
      -c http.version=HTTP/1.1 \
      -c http.maxRequests=1 \
      submodule sync --recursive; then
      echo "${LOG_WARN}WARNING:${NC} submodule sync failed"
    elif ! git -C "$source_dir" \
      -c safe.directory="*" \
      -c http.version=HTTP/1.1 \
      -c http.maxRequests=1 \
      submodule update --init --recursive; then
      echo "${LOG_WARN}WARNING:${NC} submodule update failed"
    elif [ ! -d "$source_dir/third_party/cutlass" ]; then
      echo "${LOG_WARN}WARNING:${NC} CUTLASS submodule directory is missing"
    elif [ ! -f "$source_dir/third_party/cutlass/include/cutlass/matrix.h" ]; then
      echo "${LOG_WARN}WARNING:${NC} CUTLASS matrix.h is missing"
    else
      echo "${LOG_OK}SUCCESS:${NC} Nunchaku submodules initialized"
      return 0
    fi

    if [ "$attempt" -lt "$NUNCHAKU_GIT_RETRIES" ]; then
      echo "Waiting ${NUNCHAKU_GIT_RETRY_DELAY}s before retry..."
      sleep "$NUNCHAKU_GIT_RETRY_DELAY"
    fi
  done

  return 1
}

find_existing_clone() {
  local build_root=$1
  local pattern=$2
  local candidate

  # Find the newest previous temporary clone.
  for candidate in $(find "$build_root" -maxdepth 1 -type d -name "${pattern}-*" | sort -r); do
    if [ -d "$candidate/.git" ]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
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

source /comfy/mnt/venv/bin/activate \
  || error_exit "Failed to activate virtualenv"

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

if ! [[ "$NUNCHAKU_GIT_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
  error_exit "NUNCHAKU_GIT_RETRIES must be a positive integer"
fi

if ! [[ "$NUNCHAKU_GIT_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
  error_exit "NUNCHAKU_GIT_RETRY_DELAY must be a non-negative integer"
fi

if [ -n "$NUNCHAKU_NVCC_THREADS" ] && \
   ! [[ "$NUNCHAKU_NVCC_THREADS" =~ ^[1-9][0-9]*$ ]]; then
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
echo " - git http.version: HTTP/1.1"
echo " - git http.maxRequests: 1"
echo " - git retries: $NUNCHAKU_GIT_RETRIES"

if [ -n "$NUNCHAKU_NVCC_THREADS" ]; then
  echo " - nvcc_threads override: $NUNCHAKU_NVCC_THREADS"
else
  echo " - nvcc_threads: Nunchaku default"
fi

# ---------------------------------------------------------------------------
# EXISTING SOURCE
# ---------------------------------------------------------------------------

if [ -d "$source_dir" ] && [ "$FORCE_REINSTALL" = "false" ]; then
  echo "${LOG_INFO}INFO:${NC} Using existing Nunchaku source: $source_dir"

  if [ ! -d "$source_dir/.git" ]; then
    error_exit "Existing Nunchaku source is not a Git repository: $source_dir"
  fi

  # The previous version could have cloned the main repository but failed
  # while downloading submodules. Finish that operation here instead of
  # downloading Nunchaku again.
  update_submodules_with_retry "$source_dir" \
    || error_exit "Failed to initialize Nunchaku submodules"

  patch_cutlass_for_cuda_13_3 "$source_dir"

  install_nunchaku "$source_dir" \
    || error_exit "Failed to build Nunchaku"

  nunchaku_is_importable \
    || error_exit "Nunchaku installed but its native module is not importable"

  echo "${LOG_OK}SUCCESS:${NC} Nunchaku installed successfully"
  exit 0
fi

# ---------------------------------------------------------------------------
# FIND PREVIOUS INCOMPLETE TEMPORARY CLONE
# ---------------------------------------------------------------------------

temporary_dir=""

if [ "$FORCE_REINSTALL" = "false" ]; then
  temporary_dir=$(find_existing_clone \
    "$build_root" \
    "nunchaku-${nunchaku_version}" \
    || true)

  if [ -n "$temporary_dir" ]; then
    echo "${LOG_INFO}INFO:${NC} Found previous Nunchaku clone:"
    echo "     $temporary_dir"
    echo "     Reusing it instead of cloning Nunchaku again."
  fi
fi

# ---------------------------------------------------------------------------
# CLONE MAIN REPOSITORY WITHOUT SUBMODULES
# ---------------------------------------------------------------------------

if [ -z "$temporary_dir" ]; then
  temporary_dir="${source_dir}-$(date +%Y%m%d%H%M%S)"

  echo "Cloning Nunchaku main repository without submodules..."
  echo "Temporary source: $temporary_dir"

  git \
    -c http.version=HTTP/1.1 \
    -c http.maxRequests=1 \
    clone \
    --branch "$nunchaku_version" \
    https://github.com/nunchaku-tech/nunchaku.git \
    "$temporary_dir" \
    || error_exit "Failed to clone Nunchaku main repository"
fi

# ---------------------------------------------------------------------------
# INITIALIZE SUBMODULES SEPARATELY WITH RETRIES
# ---------------------------------------------------------------------------

update_submodules_with_retry "$temporary_dir" \
  || error_exit "Failed to initialize Nunchaku submodules after retries"

# ---------------------------------------------------------------------------
# PATCH BEFORE PROMOTING SOURCE
# ---------------------------------------------------------------------------

patch_cutlass_for_cuda_13_3 "$temporary_dir"

# ---------------------------------------------------------------------------
# PROMOTE TEMPORARY SOURCE TO FINAL SOURCE DIRECTORY
# ---------------------------------------------------------------------------

backup_dir=""

if [ -d "$source_dir" ]; then
  backup_dir="${source_dir}.backup.$$"

  mv "$source_dir" "$backup_dir" \
    || error_exit "Failed to preserve existing Nunchaku source"
fi

if ! mv "$temporary_dir" "$source_dir"; then
  if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    mv "$backup_dir" "$source_dir"
  fi

  error_exit "Failed to promote Nunchaku source to $source_dir"
fi

# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

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



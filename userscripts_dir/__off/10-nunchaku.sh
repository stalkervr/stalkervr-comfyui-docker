#!/bin/bash

# Pre-requisites:
# - 00-nvidia-dev.sh

# https://github.com/nunchaku-tech/nunchaku
nunchaku_version="v1.2.1"

export NUNCHAKU_INSTALL_MODE=FAST

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

FORCE_REINSTALL="${FORCE_REINSTALL:-false}"

default_max_jobs=$(nproc --all)
if [ "$default_max_jobs" -gt 8 ]; then
  default_max_jobs=8
fi

NUNCHAKU_MAX_JOBS="${NUNCHAKU_MAX_JOBS:-$default_max_jobs}"

# Leave empty to use Nunchaku default.
NUNCHAKU_NVCC_THREADS="${NUNCHAKU_NVCC_THREADS:-}"

NUNCHAKU_GIT_RETRIES="${NUNCHAKU_GIT_RETRIES:-5}"
NUNCHAKU_GIT_RETRY_DELAY="${NUNCHAKU_GIT_RETRY_DELAY:-5}"

# Maximum time for ONE repository clone.
NUNCHAKU_GIT_TIMEOUT="${NUNCHAKU_GIT_TIMEOUT:-300}"

NUNCHAKU_GIT_HTTP_VERSION="${NUNCHAKU_GIT_HTTP_VERSION:-HTTP/1.1}"
NUNCHAKU_GIT_MAX_REQUESTS="${NUNCHAKU_GIT_MAX_REQUESTS:-1}"

# ---------------------------------------------------------------------------
# COLORS
# ---------------------------------------------------------------------------

LOG_ERR=$(printf '\033[0;41m')
LOG_WARN=$(printf '\033[0;33m')
LOG_OK=$(printf '\033[0;32m')
LOG_INFO=$(printf '\033[0m')
NC=$(printf '\033[0m')

set -e

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo "$*"
  echo "!! Exiting nunchaku script (ID: $$)"
  exit 1
}

# ---------------------------------------------------------------------------
# GIT WRAPPER
# ---------------------------------------------------------------------------

git_nunchaku() {
  git \
    -c safe.directory="*" \
    -c http.version="$NUNCHAKU_GIT_HTTP_VERSION" \
    -c http.maxRequests="$NUNCHAKU_GIT_MAX_REQUESTS" \
    "$@"
}

# ---------------------------------------------------------------------------
# PYTHON CHECK
# ---------------------------------------------------------------------------

nunchaku_is_importable() {
  python -c 'import nunchaku; import nunchaku._C' \
    > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# CUTLASS PATCH
# ---------------------------------------------------------------------------

patch_cutlass_header() {
  local matrix_header="$1"

  [ -f "$matrix_header" ] || return 0

  if grep -q '\.set_slice3x3(' "$matrix_header"; then
    echo "Patching obsolete CUTLASS set_slice3x3 calls:"
    echo "  $matrix_header"

    sed -i \
      's/\.set_slice3x3(/.set_slice_3x3(/g' \
      "$matrix_header"
  fi

  if grep -q '\.set_slice3x3(' "$matrix_header"; then
    error_exit "Failed to patch CUTLASS matrix header: $matrix_header"
  fi
}

patch_cutlass_for_cuda_13_3() {
  local source_dir="$1"

  local main_cutlass_header
  local nested_cutlass_header

  main_cutlass_header="$source_dir/third_party/cutlass/include/cutlass/matrix.h"

  nested_cutlass_header="$source_dir/third_party/Block-Sparse-Attention/csrc/cutlass/include/cutlass/matrix.h"

  echo
  echo "Checking CUTLASS headers..."

  if [ ! -f "$main_cutlass_header" ]; then
    error_exit "CUTLASS matrix.h not found: $main_cutlass_header"
  fi

  patch_cutlass_header "$main_cutlass_header"

  if [ -f "$nested_cutlass_header" ]; then
    patch_cutlass_header "$nested_cutlass_header"
  else
    echo "${LOG_INFO}INFO:${NC} No nested CUTLASS matrix.h"
  fi
}

# ---------------------------------------------------------------------------
# REPOSITORY VALIDATION
# ---------------------------------------------------------------------------

validate_nunchaku_repository() {
  local source_dir="$1"

  [ -d "$source_dir/.git" ] || {
    echo "${LOG_WARN}WARNING:${NC} Missing .git"
    return 1
  }

  [ -f "$source_dir/.gitmodules" ] || {
    echo "${LOG_WARN}WARNING:${NC} Missing .gitmodules"
    return 1
  }

  git_nunchaku -C "$source_dir" \
    rev-parse --verify HEAD >/dev/null 2>&1 \
    || {
      echo "${LOG_WARN}WARNING:${NC} Invalid repository HEAD"
      return 1
    }

  return 0
}

# ---------------------------------------------------------------------------
# REQUIRED DIRECTORIES
# ---------------------------------------------------------------------------

validate_nunchaku_tree() {
  local source_dir="$1"

  local required_dir

  echo
  echo "Validating Nunchaku source tree..."

  for required_dir in \
    "$source_dir/third_party/Block-Sparse-Attention/csrc/block_sparse_attn" \
    "$source_dir/third_party/cutlass/include" \
    "$source_dir/third_party/json/include" \
    "$source_dir/third_party/mio/include" \
    "$source_dir/third_party/spdlog/include"
  do
    if [ ! -d "$required_dir" ]; then
      echo "${LOG_WARN}WARNING:${NC} Missing:"
      echo "  $required_dir"
      return 1
    fi
  done

  if [ ! -f "$source_dir/third_party/cutlass/include/cutlass/matrix.h" ]; then
    echo "${LOG_WARN}WARNING:${NC} Missing CUTLASS matrix.h"
    return 1
  fi

  echo "${LOG_OK}SUCCESS:${NC} All required Nunchaku directories exist"

  return 0
}

# ---------------------------------------------------------------------------
# GET SUBMODULE SHA FROM NUNCHAKU GITLINK
# ---------------------------------------------------------------------------

get_gitlink_sha() {
  local source_dir="$1"
  local path="$2"

  git_nunchaku -C "$source_dir" \
    ls-tree HEAD -- "$path" |
    awk '$1 == "160000" {print $3}'
}

# ---------------------------------------------------------------------------
# CLONE ONE REPOSITORY AT EXACT COMMIT
# ---------------------------------------------------------------------------

clone_repo_at_commit() {
  local name="$1"
  local url="$2"
  local commit="$3"
  local destination="$4"

  local attempt
  local temp_dir

  if [ -z "$commit" ]; then
    echo "${LOG_WARN}WARNING:${NC} Empty commit for $name"
    return 1
  fi

  echo
  echo "============================================================"
  echo "Cloning submodule: $name"
  echo "============================================================"
  echo "URL:    $url"
  echo "COMMIT: $commit"
  echo "TIMEOUT: ${NUNCHAKU_GIT_TIMEOUT}s"
  echo

  for attempt in $(seq 1 "$NUNCHAKU_GIT_RETRIES"); do

    echo "Attempt $attempt/$NUNCHAKU_GIT_RETRIES"

    temp_dir="${destination}.tmp.$$.$attempt"

    rm -rf "$temp_dir"

    if timeout --foreground "$NUNCHAKU_GIT_TIMEOUT" \
      git_nunchaku clone \
        --no-checkout \
        "$url" \
        "$temp_dir"; then

      echo "Repository downloaded."

      if timeout --foreground "$NUNCHAKU_GIT_TIMEOUT" \
        git_nunchaku -C "$temp_dir" \
          checkout --detach "$commit"; then

        echo "Checked out exact commit."

        if git_nunchaku -C "$temp_dir" \
          rev-parse HEAD | grep -qx "$commit"; then

          rm -rf "$destination"

          if mv "$temp_dir" "$destination"; then
            echo "${LOG_OK}SUCCESS:${NC} $name ready"
            return 0
          fi
        fi
      fi
    fi

    echo "${LOG_WARN}WARNING:${NC} Failed to clone $name"

    rm -rf "$temp_dir"

    if [ "$attempt" -lt "$NUNCHAKU_GIT_RETRIES" ]; then
      echo "Waiting ${NUNCHAKU_GIT_RETRY_DELAY}s..."
      sleep "$NUNCHAKU_GIT_RETRY_DELAY"
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# CLONE ALL NUNCHAKU SUBMODULES SEQUENTIALLY
# ---------------------------------------------------------------------------

clone_nunchaku_submodules() {
  local source_dir="$1"

  local sha_block_sparse
  local sha_cutlass
  local sha_json
  local sha_mio
  local sha_spdlog

  sha_block_sparse=$(get_gitlink_sha \
    "$source_dir" \
    "third_party/Block-Sparse-Attention")

  sha_cutlass=$(get_gitlink_sha \
    "$source_dir" \
    "third_party/cutlass")

  sha_json=$(get_gitlink_sha \
    "$source_dir" \
    "third_party/json")

  sha_mio=$(get_gitlink_sha \
    "$source_dir" \
    "third_party/mio")

  sha_spdlog=$(get_gitlink_sha \
    "$source_dir" \
    "third_party/spdlog")

  echo
  echo "Pinned submodule commits:"
  echo "  Block-Sparse-Attention: $sha_block_sparse"
  echo "  cutlass:               $sha_cutlass"
  echo "  json:                  $sha_json"
  echo "  mio:                   $sha_mio"
  echo "  spdlog:                $sha_spdlog"

  # IMPORTANT:
  # These are deliberately sequential.
  # No `git submodule update` is used anywhere.

  clone_repo_at_commit \
    "Block-Sparse-Attention" \
    "https://github.com/sxtyzhangzk/Block-Sparse-Attention.git" \
    "$sha_block_sparse" \
    "$source_dir/third_party/Block-Sparse-Attention" \
    || return 1

  clone_repo_at_commit \
    "cutlass" \
    "https://github.com/NVIDIA/cutlass.git" \
    "$sha_cutlass" \
    "$source_dir/third_party/cutlass" \
    || return 1

  clone_repo_at_commit \
    "json" \
    "https://github.com/nlohmann/json.git" \
    "$sha_json" \
    "$source_dir/third_party/json" \
    || return 1

  clone_repo_at_commit \
    "mio" \
    "https://github.com/vimpunk/mio.git" \
    "$sha_mio" \
    "$source_dir/third_party/mio" \
    || return 1

  clone_repo_at_commit \
    "spdlog" \
    "https://github.com/gabime/spdlog.git" \
    "$sha_spdlog" \
    "$source_dir/third_party/spdlog" \
    || return 1

  echo
  echo "${LOG_OK}SUCCESS:${NC} All Nunchaku submodules cloned sequentially"

  return 0
}

# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

install_nunchaku() {
  local source_dir="$1"

  local build_cmd="$source_dir/build.cmd"
  local build_log="$source_dir/build.log"

  {
    echo '#!/bin/bash'
    echo 'set -e'

    printf 'export EXT_PARALLEL=%q\n' "$NUNCHAKU_MAX_JOBS"
    printf 'export MAX_JOBS=%q\n' "$NUNCHAKU_MAX_JOBS"

    if [ -n "$NUNCHAKU_NVCC_THREADS" ]; then
      printf 'export NVCC_APPEND_FLAGS=%q\n' \
        "--threads $NUNCHAKU_NVCC_THREADS"
    else
      echo 'unset NVCC_APPEND_FLAGS'
    fi

    printf 'cd %q\n' "$source_dir"
    printf '%s -e . --no-build-isolation\n' "$PIP3_CMD"
  } > "$build_cmd"

  chmod +x "$build_cmd"

  echo
  echo "Build command:"
  echo "\"$(tail -n 1 "$build_cmd")\""

  script -a -e -c "$build_cmd" "$build_log"
}

# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------

source /comfy/mnt/venv/bin/activate \
  || error_exit "Failed to activate virtualenv"

if [ "$FORCE_REINSTALL" = "false" ] &&
   pip show nunchaku > /dev/null 2>&1; then

  if nunchaku_is_importable; then
    echo "${LOG_INFO}INFO:${NC} Nunchaku is already installed and importable."
    echo "Set FORCE_REINSTALL=true to force rebuild."
    exit 0
  fi

  echo "${LOG_WARN}WARNING:${NC} Nunchaku metadata exists but native module is not importable."
fi

if [ "$FORCE_REINSTALL" = "true" ]; then
  echo "${LOG_INFO}INFO:${NC} FORCE_REINSTALL=true"
fi

echo
echo "** Installing Nunchaku **"

# ---------------------------------------------------------------------------
# PREREQUISITES
# ---------------------------------------------------------------------------

command -v nvcc > /dev/null 2>&1 \
  || error_exit "nvcc not found"

pip3 show setuptools > /dev/null 2>&1 \
  || error_exit "setuptools not installed"

pip3 show ninja > /dev/null 2>&1 \
  || error_exit "ninja not installed"

[ -n "${PIP3_CMD:-}" ] \
  || error_exit "PIP3_CMD is not set"

[[ "$NUNCHAKU_MAX_JOBS" =~ ^[1-9][0-9]*$ ]] \
  || error_exit "NUNCHAKU_MAX_JOBS must be a positive integer"

[[ "$NUNCHAKU_GIT_RETRIES" =~ ^[1-9][0-9]*$ ]] \
  || error_exit "NUNCHAKU_GIT_RETRIES must be a positive integer"

[[ "$NUNCHAKU_GIT_RETRY_DELAY" =~ ^[0-9]+$ ]] \
  || error_exit "NUNCHAKU_GIT_RETRY_DELAY must be >= 0"

[[ "$NUNCHAKU_GIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || error_exit "NUNCHAKU_GIT_TIMEOUT must be a positive integer"

[[ "$NUNCHAKU_GIT_MAX_REQUESTS" =~ ^[1-9][0-9]*$ ]] \
  || error_exit "NUNCHAKU_GIT_MAX_REQUESTS must be a positive integer"

# ---------------------------------------------------------------------------
# BUILD PATH
# ---------------------------------------------------------------------------

build_base_file="/comfy/mnt/venv/.build_base.txt"

[ -s "$build_base_file" ] \
  || error_exit "$build_base_file not found or empty"

BUILD_BASE=$(cat "$build_base_file")

torch_version=$(python - <<'PY'
import torch
print(".".join(torch.__version__.split("+")[0].split(".")[:2]))
PY
) || error_exit "Failed to determine Torch version"

[ -n "$torch_version" ] \
  || error_exit "Torch version is empty"

build_root="/comfy/mnt/src/${BUILD_BASE}/Torch_${torch_version}"

source_dir="$build_root/nunchaku-${nunchaku_version}"

mkdir -p "$build_root"

echo
echo "Build configuration:"
echo "  BUILD_BASE:             $BUILD_BASE"
echo "  Torch:                  $torch_version"
echo "  Nunchaku:               $nunchaku_version"
echo "  max_jobs:               $NUNCHAKU_MAX_JOBS"
echo "  git http.version:       $NUNCHAKU_GIT_HTTP_VERSION"
echo "  git maxRequests:        $NUNCHAKU_GIT_MAX_REQUESTS"
echo "  git timeout:            ${NUNCHAKU_GIT_TIMEOUT}s"
echo "  git retries:            $NUNCHAKU_GIT_RETRIES"
echo "  git retry delay:        ${NUNCHAKU_GIT_RETRY_DELAY}s"

# ---------------------------------------------------------------------------
# EXISTING SOURCE
# ---------------------------------------------------------------------------

if [ -d "$source_dir" ] && [ "$FORCE_REINSTALL" = "false" ]; then

  echo
  echo "Existing Nunchaku source found:"
  echo "  $source_dir"

  if validate_nunchaku_repository "$source_dir" &&
     validate_nunchaku_tree "$source_dir"; then

    echo "${LOG_OK}SUCCESS:${NC} Existing source tree is complete."

    patch_cutlass_for_cuda_13_3 "$source_dir"

    install_nunchaku "$source_dir" \
      || error_exit "Failed to build Nunchaku"

    nunchaku_is_importable \
      || error_exit "Nunchaku native module is not importable"

    echo "${LOG_OK}SUCCESS:${NC} Nunchaku installed successfully"
    exit 0
  fi

  echo "${LOG_WARN}WARNING:${NC} Existing source is incomplete/corrupted."

  broken_dir="${source_dir}.broken.$$"

  mv "$source_dir" "$broken_dir" \
    || error_exit "Failed to move broken Nunchaku source"

  echo "Broken source preserved at:"
  echo "  $broken_dir"
fi

# ---------------------------------------------------------------------------
# FRESH MAIN CLONE
# ---------------------------------------------------------------------------

temporary_dir="${source_dir}-$(date +%Y%m%d%H%M%S)-$$"

rm -rf "$temporary_dir"

echo
echo "============================================================"
echo "Cloning Nunchaku main repository"
echo "============================================================"
echo "Version: $nunchaku_version"
echo "Destination: $temporary_dir"
echo
echo "IMPORTANT: submodules are NOT initialized by Git."
echo "They will be cloned sequentially by this script."
echo

if ! timeout --foreground "$NUNCHAKU_GIT_TIMEOUT" \
  git_nunchaku clone \
    --branch "$nunchaku_version" \
    --no-recurse-submodules \
    https://github.com/nunchaku-tech/nunchaku.git \
    "$temporary_dir"; then

  rm -rf "$temporary_dir"

  error_exit "Failed or timed out cloning Nunchaku main repository"
fi

# ---------------------------------------------------------------------------
# VALIDATE MAIN REPOSITORY
# ---------------------------------------------------------------------------

validate_nunchaku_repository "$temporary_dir" \
  || error_exit "Fresh Nunchaku clone is invalid"

# ---------------------------------------------------------------------------
# CLONE SUBMODULES ONE BY ONE
# ---------------------------------------------------------------------------

clone_nunchaku_submodules "$temporary_dir" \
  || error_exit "Failed to clone Nunchaku submodules"

# ---------------------------------------------------------------------------
# VALIDATE TREE
# ---------------------------------------------------------------------------

validate_nunchaku_tree "$temporary_dir" \
  || error_exit "Nunchaku source tree is incomplete"

# ---------------------------------------------------------------------------
# PATCH CUTLASS
# ---------------------------------------------------------------------------

patch_cutlass_for_cuda_13_3 "$temporary_dir"

# ---------------------------------------------------------------------------
# PROMOTE SOURCE
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

  error_exit "Failed to promote Nunchaku source"
fi

# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

if ! install_nunchaku "$source_dir" ||
   ! nunchaku_is_importable; then

  failed_dir="${source_dir}.failed.$$"

  if mv "$source_dir" "$failed_dir" 2>/dev/null; then
    echo "${LOG_WARN}WARNING:${NC} Failed source preserved at:"
    echo "  $failed_dir"
  fi

  if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    mv "$backup_dir" "$source_dir" \
      || error_exit "Failed to restore previous Nunchaku source"
  fi

  error_exit "Failed to build or import Nunchaku"
fi

# ---------------------------------------------------------------------------
# CLEANUP
# ---------------------------------------------------------------------------

if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
  rm -rf "$backup_dir"
fi

echo
echo "============================================================"
echo "${LOG_OK}SUCCESS: Nunchaku built and imported successfully${NC}"
echo "============================================================"

exit 0

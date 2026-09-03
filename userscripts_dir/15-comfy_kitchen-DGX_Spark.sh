#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh

# Install comfy_kitchen (from git)
# 
# https://github.com/Comfy-Org/comfy-kitchen/

# --- CONFIGURATION ---
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
# ---------------------

# --- COLOR CODES (for console)---
LOG_ERR=$(printf '\033[0;41m') # White on RED BG
# LOG_ERR=$(printf '\033[0;91m') # Red on Black BG
# LOG_ERR=$(printf '\033[0m') # No Color

LOG_WARN=$(printf '\033[0;33m') # Yellow
# LOG_WARN=$(printf '\033[0m') # No Color 

LOG_OK=$(printf '\033[0;32m') # GREEN
# LOG_OK=$(printf '\033[0m') # No Color 

# LOG_INFO=$(printf '\033[0;32m') # Green 
LOG_INFO=$(printf '\033[0m') # No Color

NC=$(printf '\033[0m') # No Color
# --------------------------------

set -e

error_exit() {
 echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo "!! Exiting comfy_kitchen script (ID: $$)"
  exit 1
}

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

# --- CHECK EXISTING INSTALLATION ---
if [ "$FORCE_REINSTALL" = "false" ]; then
    if pip show comfy_kitchen > /dev/null 2>&1; then
        echo "${LOG_INFO}INFO:${NC} comfy_kitchen is already installed."
        echo "     (Set FORCE_REINSTALL=true in script to force rebuild/reinstall)"
        exit 0
    fi
else
    echo "${LOG_INFO}INFO:${NC} FORCE_REINSTALL is true. Proceeding..."
fi
# -----------------------------------

echo "** Installing comfy_kitchen on Arm64 (DGX10) **"

# Confirm we are on arm64
if [ "$(uname -m)" != "aarch64" ]; then
    echo   "${LOG_WARN}WARNING:${NC} This script is for arm64 only, exiting"
    exit 0
fi

# We need both uv and the cache directory to enable build with uv
use_uv=true
uv="/comfy/mnt/venv/bin/uv"
uv_cache="/comfy/mnt/uv_cache"
if [ ! -x "$uv" ] || [ ! -d "$uv_cache" ]; then use_uv=false; fi

echo "Checking if nvcc is available"
if ! command -v nvcc &> /dev/null; then
    error_exit " !! nvcc not found, canceling run"
fi

if pip3 show setuptools &>/dev/null; then
  echo " ++ setuptools installed"
else
  error_exit " !! setuptools not installed, canceling run"
fi
if pip3 show ninja &>/dev/null; then
  echo " ++ ninja installed"
else
  error_exit " !! ninja not installed, canceling run"
fi

cd /comfy/mnt
bb="venv/.build_base.txt"
if [ ! -f $bb ]; then error_exit "${bb} not found"; fi
BUILD_BASE=$(cat $bb)
# extract CUDA version from build base
CUDA_VERSION=$(echo $BUILD_BASE | grep -oP 'cuda\d+\.\d+')
if [ -z "$CUDA_VERSION" ]; then error_exit "CUDA version not found in build base"; fi

echo "CUDA version: $CUDA_VERSION"

if pip3 show torch &>/dev/null; then
  torch_version=$(pip3 show torch | grep Version | awk '{print $2}' | cut -d'.' -f1-2)
else
  error_exit "torch not installed, canceling run"
fi

echo "PyTorch version: $torch_version"

echo "PIP3_CMD: \"${PIP3_CMD}\""
if [ ! -d src ]; then mkdir src; fi
cd src

mkdir -p ${BUILD_BASE}
if [ ! -d ${BUILD_BASE} ]; then error_exit "${BUILD_BASE} not found"; fi
cd ${BUILD_BASE}

if [ -z "$torch_version" ]; then error_exit "error getting torch version, canceling run"; fi
td="Torch_${torch_version}"
if [ ! -d $td ]; then mkdir $td; fi
cd $td

dd="/comfy/mnt/src/${BUILD_BASE}/$td/comfy_kitchen-git"
if [ -d $dd ]; then
  echo "${LOG_WARN}WARNING:${NC} comfy_kitchen source already present, you must delete $dd to force reinstallation"
  exit 0
fi
tdd="$dd-`date +%Y%m%d%H%M%S`"
mkdir -p $tdd

# we are not downloading the source code, we are building from git, as described in the xformers documentation
# Set build parallelism based on available CPU cores (matching SageAttention/nunchaku pattern)
numproc=$(nproc --all)
echo " - numproc: $numproc"
ext_parallel=$(( numproc / 2 ))
if [ "$ext_parallel" -lt 1 ]; then ext_parallel=1; fi
echo " - ext_parallel: $ext_parallel"
num_threads=$(( numproc / 2 ))
if [ "$num_threads" -lt 1 ]; then num_threads=1; fi
echo " - num_threads: $num_threads"

if [ "A$use_uv" == "Atrue" ]; then
  echo "== Using uv"
  echo " - uv: $uv"
  echo " - uv_cache: $uv_cache"
else
  echo "== Using pip"
  echo " - TORCH_INDEX_URL: $TORCH_INDEX_URL"
fi

echo "${PIP3_CMD} nanobind" > $tdd/build.cmd

CMD="EXT_PARALLEL=$ext_parallel NVCC_APPEND_FLAGS=\"--threads $num_threads\" MAX_JOBS=$numproc ${PIP3_CMD} comfy_kitchen --no-build-isolation git+https://github.com/Comfy-Org/comfy-kitchen.git@main#egg=comfy_kitchen"
echo "CMD: \"${CMD}\""
echo $CMD >> $tdd/build.cmd; chmod +x $tdd/build.cmd

script -a -e -c $tdd/build.cmd $tdd/build.log || error_exit "Failed to build comfy_kitchen"
cd ..
mv $tdd $dd
echo "${LOG_INFO}INFO:${NC} comfy_kitchen built successfully"
exit 0

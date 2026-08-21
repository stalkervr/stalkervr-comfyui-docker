#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh

# Install onnxruntime-gpu from PyPI
#
# https://onnxruntime.ai/
# https://github.com/microsoft/onnxruntime

# --- CONFIGURATION ---
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
# ---------------------

# Building it from source takes a long time: try not to delete it if that is your goal
# ONLY set to true if you built from source (ie no wheel available --there are some for x86_64)
ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT="${ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT:-false}"

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
  echo "$*"
  echo -e "!! Exiting onnxruntime-gpu Script (ID: $$)"
  exit 1
}

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

echo "Checking for existing onnxruntime installations..."

# Check if onnxruntime-gpu is installed
if pip show onnxruntime-gpu > /dev/null 2>&1; then
    # Check if standard onnxruntime (CPU) is ALSO installed
    if pip show onnxruntime > /dev/null 2>&1; then
        # Case: GPU installed AND CPU installed -> Remove both, then install GPU
        echo "${LOG_WARN}Warning:${NC} Found BOTH onnxruntime and onnxruntime-gpu."
        if [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "true" ]; then
            echo "Uninstalling CPU to ensure clean GPU installation..."
            echo "${LOG_WARN}Warning:${NC} ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT is true. Keeping onnxruntime-gpu..."
            pip uninstall -y onnxruntime || error_exit "Failed to uninstall onnxruntime"
            exit 0
        else
            echo "Uninstalling both to ensure clean GPU installation..."
            pip uninstall -y onnxruntime onnxruntime-gpu || error_exit "Failed to uninstall conflicting packages"
        fi
    else
        # Case: GPU installed AND CPU NOT installed
        if [ "$FORCE_REINSTALL" = "false" ] || [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "true" ]; then
            echo "${LOG_INFO}INFO:${NC} onnxruntime-gpu is already installed and clean."
            echo "     (Set FORCE_REINSTALL=true in script to force reinstall)"
            exit 0
        else
            pip uninstall -y onnxruntime-gpu || error_exit "Failed to uninstall onnxruntime-gpu"
        fi
     fi
else
    # Check if standard onnxruntime (CPU) is installed
    if pip show onnxruntime > /dev/null 2>&1; then
        # Case: GPU NOT installed AND CPU installed -> Remove CPU, then install GPU
        echo "${LOG_WARN}Warning:${NC} Found onnxruntime (CPU). Uninstalling it to replace with GPU version..."
        pip uninstall -y onnxruntime || error_exit "Failed to uninstall onnxruntime"
    else
        # Case: GPU NOT installed AND CPU NOT installed -> Install GPU
        echo "${LOG_INFO}INFO:${NC} No conflicting 'onnxruntime' (CPU) package found. Proceeding..."
    fi
fi

# We need both uv and the cache directory to enable build with uv
use_uv=true
uv="/comfy/mnt/venv/bin/uv"
uv_cache="/comfy/mnt/uv_cache"
if [ ! -x "$uv" ] || [ ! -d "$uv_cache" ]; then use_uv=false; fi

# If aarch64 (GB10), we must build (no whl available)
if [ "$(uname -m)" == "aarch64" ]; then must_build=true; fi

# https://github.com/thewh1teagle/spark-docs/blob/main/BUILD_ONNXRUNTIME.md
if [ "A$must_build" == "Atrue" ]; then
    echo "Building onnxruntime-gpu from source..."

    echo "Checking if nvcc is available"
    if ! command -v nvcc &> /dev/null; then
        error_exit " !! nvcc not found, canceling run"
    fi

    echo "Checking if setuptools is installed"
    if pip3 show setuptools &>/dev/null; then
        echo " ++ setuptools installed"
    else
        error_exit " !! setuptools not installed, canceling run"
    fi
    echo "Checking if ninja is installed"
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

    # until this is fixed, the build will not work on 13.2 
    if [ "$CUDA_VERSION" == "cuda13.2" ]; then
        echo "onnxruntime-gpu build is not currently working with CUDA 13.2. For more details see https://github.com/microsoft/onnxruntime/issues/28023 (when this is marked as fixed, please let me know so I can update the script)"
        exit 0
    fi
    # or CUDA 13.3 yet
    if [ "$CUDA_VERSION" == "cuda13.3" ]; then
        echo "onnxruntime-gpu build is not currently working with CUDA 13.3. For more details see https://github.com/microsoft/onnxruntime/issues/28023 (when this is marked as fixed, please let me know so I can update the script)"
        exit 0
    fi

    if pip3 show torch &>/dev/null; then
        torch_version=$(pip3 show torch | grep Version | awk '{print $2}' | cut -d'.' -f1-2)
    else
        error_exit "torch not installed, canceling run"
    fi

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

    dd="/comfy/mnt/src/${BUILD_BASE}/$td/onnxruntime"
    if [ -d $dd ] && [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "false" ]; then
        echo "${LOG_WARN}WARNING:${NC} onnxruntime source already present, you must delete $dd to force reinstallation"
        exit 0
    fi

    if [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "true" ]; then
        echo "${LOG_WARN}Not downloading from git, using existing source, if it exists"
        tdd=$dd
        if [ ! -d $tdd ]; then error_exit "$tdd not found, disable ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT to force reinstallation re-enabling it"; fi
    else
        tdd="$dd-`date +%Y%m%d%H%M%S`"
        mkdir -p $tdd
        git clone --recursive https://github.com/microsoft/onnxruntime $tdd
    fi

    cd $tdd

    # This heredoc is expanded now; escape variables that the generated script
    # must evaluate after setting its own environment.
    cat > $tdd/build.cmd << EOF
#!/bin/bash
export CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)
export CPLUS_INCLUDE_PATH=/usr/local/cuda/targets/sbsa-linux/include/cccl:\$CPLUS_INCLUDE_PATH
export C_INCLUDE_PATH=/usr/local/cuda/targets/sbsa-linux/include/cccl:\$C_INCLUDE_PATH
export CPATH=/usr/local/cuda/targets/sbsa-linux/include/cccl:\$CPATH

source /comfy/mnt/venv/bin/activate

find . -type f -name 'CMakeCache.txt' -delete

./build.sh \
    --config Release \
    --build_shared_lib \
    --parallel \$CMAKE_BUILD_PARALLEL_LEVEL \
    --nvcc_threads 1 \
    --use_cuda \
    --cuda_home /usr/local/cuda \
    --cudnn_home /usr \
    --cmake_extra_defines \
      "CMAKE_CUDA_ARCHITECTURES=121" \
      "CMAKE_CUDA_FLAGS=-Xcompiler -fpermissive" \
      "CUDNN_INCLUDE_DIR=/usr/include/aarch64-linux-gnu" \
      "CUDNN_LIBRARY=/usr/lib/aarch64-linux-gnu/libcudnn.so" \
      "onnxruntime_BUILD_UNIT_TESTS=OFF" \
    --cmake_generator Ninja  \
    --use_binskim_compliant_compile_flags  \
    --build_wheel \
    --skip_tests

if [ \$? -ne 0 ]; then echo "Failed to build onnxruntime-gpu"; exit 1; fi

${PIP3_CMD} "numpy<2"
${PIP3_CMD} build/Linux/Release/dist/onnxruntime_gpu-*.whl
EOF

    chmod +x $tdd/build.cmd
    script -a -e -c $tdd/build.cmd $tdd/build.log || error_exit "Failed to build onnxruntime-gpu"
    cd ..
    if [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "false" ]; then
      mv $tdd $dd
    fi
    echo "${LOG_INFO}INFO:${NC} onnxruntime-gpu built successfully"
    exit 0
fi

echo "== PIP3_CMD: \"${PIP3_CMD}\""
if [ "A$use_uv" == "Atrue" ]; then
  echo "== Using uv"
  echo " - uv: $uv"
  echo " - uv_cache: $uv_cache"
else
  echo "== Using pip"
fi

CMD="${PIP3_CMD} onnxruntime-gpu"
echo "CMD: \"${CMD}\""
${CMD} || error_exit "Failed to install onnxruntime-gpu"
echo "${LOG_OK}SUCCESS:${NC} onnxruntime-gpu installed"

exit 0

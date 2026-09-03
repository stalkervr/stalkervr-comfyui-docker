#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh

# ==============================================================================
#           Fix simsimd ImportError for Ubuntu 24 Docker Containers
# ==============================================================================
#
# This script resolves the "ImportError: libmvec-2-06864e43.28.so: cannot open
# shared object file" that can occur when trying to install e.g. Nunchaku and 
# PulID nodes.
# This error occurs because a pre-compiled Python package, simsimd, is 
# incompatible with the system libraries inside the Ubuntu 24 Docker container.
# It forces pip to reinstall the 'simsimd' package from its source code. 
# This ensures it's compiled against the correct system libraries within the 
# container. This script is built to be easily tweaked to force any package to
# be built from source, see PACKAGE_TO_FIX in Configuration.
#
# This script is designed to be run inside your ComfyUI Docker container.
# 
# WARNING: RUN THIS SCRIPT AT YOUR OWN RISK. NO WARRANTY GIVEN. NO SUPPORT.
#
# ==============================================================================

# --- CONFIGURATION ---
PACKAGE_TO_FIX="simsimd"
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
  echo -e "!! Exiting Fix Script (ID: $$)"
  exit 1
}

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

# We need both uv and the cache directory to enable build with uv
use_uv=true
uv="/comfy/mnt/venv/bin/uv"
uv_cache="/comfy/mnt/uv_cache"
if [ ! -x "$uv" ] || [ ! -d "$uv_cache" ]; then use_uv=false; fi

echo "== PIP3_CMD: \"${PIP3_CMD}\""
if [ "A$use_uv" == "Atrue" ]; then
  echo "== Using uv"
  echo " - uv: $uv"
  echo " - uv_cache: $uv_cache"
else
  echo "== Using pip"
fi

echo "${LOG_INFO}INFO:${NC} Starting $PACKAGE_TO_FIX Re-compilation Fix..."

# Re-install the package from source
echo "${LOG_INFO}INFO:${NC} Attempting to reinstall '$PACKAGE_TO_FIX' from source..."
echo "      This may take a few moments as it needs to be compiled."

# The command to force reinstallation without using pre-built binaries.
# We append the flags to the standard install command
CMD="${PIP3_CMD} --force-reinstall --no-binary :all: ${PACKAGE_TO_FIX}"
echo "CMD: \"${CMD}\""

# Run the command and catch errors
if ! ${CMD}; then
    echo "${LOG_ERR}!! FAILED to reinstall '$PACKAGE_TO_FIX'.${NC}"
    echo "!! An error occurred during the compilation/installation process."
    echo "!! You may be missing build tools like 'build-essential' or 'python3-dev'."
    echo "!! Try running: apt-get update && apt-get install -y build-essential python3-dev"
    error_exit "Compilation failed."
fi

echo "${LOG_OK}SUCCESS:${NC} Successfully re-installed '$PACKAGE_TO_FIX'."
echo "         The ImportError should now be resolved."
echo "         Please restart your ComfyUI service for the changes to take effect."

exit 0
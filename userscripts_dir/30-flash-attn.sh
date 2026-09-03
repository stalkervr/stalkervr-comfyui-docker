#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh

# Install flash-attn (https://github.com/Dao-AILab/flash-attention).
# Optional dependency for SeedVR2 and a handful of other custom nodes.
#
# Opt-in only — flash-attn rarely has prebuilt wheels for Blackwell
# (sm_120 / RTX 50 series) and building from source is heavy. Default is
# skip so container start stays fast.

# --- CONFIGURATION ---
INSTALL_FLASH_ATTN="${INSTALL_FLASH_ATTN:-false}"
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
# ---------------------

# --- COLOR CODES (for console)---
LOG_ERR=$(printf '\033[0;41m')
LOG_WARN=$(printf '\033[0;33m')
LOG_OK=$(printf '\033[0;32m')
LOG_INFO=$(printf '\033[0m')
NC=$(printf '\033[0m')
# --------------------------------

set -e

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo "!! Exiting flash-attn script (ID: $$)"
  exit 1
}

if [ "$INSTALL_FLASH_ATTN" != "true" ]; then
  echo "${LOG_INFO}INFO:${NC} flash-attn install skipped (set INSTALL_FLASH_ATTN=true to enable)"
  exit 0
fi

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

# --- CHECK EXISTING INSTALLATION ---
if [ "$FORCE_REINSTALL" = "false" ]; then
  if pip show flash-attn > /dev/null 2>&1; then
    echo "${LOG_INFO}INFO:${NC} flash-attn is already installed."
    echo "     (Set FORCE_REINSTALL=true to force reinstall)"
    exit 0
  fi
else
  echo "${LOG_INFO}INFO:${NC} FORCE_REINSTALL is true. Proceeding..."
  pip uninstall -y flash-attn || true
fi
# -----------------------------------

if ! command -v nvcc &> /dev/null; then
  echo "${LOG_WARN}WARN:${NC} nvcc not found, flash-attn build needs CUDA toolkit; skipping"
  exit 0
fi

# flash-attn 2.x requires --no-build-isolation so its setup.py can see the
# installed torch. May build from source if no matching wheel is published.
echo "++ Installing flash-attn (may build from source — this can take a while)"
CMD="${PIP3_CMD} flash-attn --no-build-isolation"
echo "CMD: \"${CMD}\""
if ${CMD}; then
  echo "${LOG_OK}SUCCESS:${NC} flash-attn installed"
else
  echo "${LOG_WARN}WARN:${NC} flash-attn install failed — it is optional, continuing"
fi

exit 0

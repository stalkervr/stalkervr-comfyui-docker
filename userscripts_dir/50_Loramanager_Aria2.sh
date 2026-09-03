#!/bin/bash

# Script that checks if aria2 is installed, and installs it if missing.
# aria2 is a lightweight multi-protocol & multi-source command-line download utility.

# --- CONFIGURATION ---
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"    # Set to true to force reinstall of aria2
# ---------------------

set -e

# --- COLOR CODES (for console)---
LOG_ERR=$(printf '\033[0;41m') # White on RED BG
LOG_WARN=$(printf '\033[0;33m') # Yellow
LOG_OK=$(printf '\033[0;32m') # GREEN
LOG_INFO=$(printf '\033[0m') # No Color
NC=$(printf '\033[0m') # No Color
# --------------------------------

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo -e "!! Exiting aria2 Install Script (ID: $$)"
  exit 1
}

echo -e "${LOG_INFO}== Checking aria2 installation...${NC}"

should_install=true

# --- CHECK EXISTING INSTALLATION ---
# The executable for aria2 is named 'aria2c'
if command -v aria2c >/dev/null 2>&1; then
    if [ "$FORCE_REINSTALL" = "true" ]; then
        echo -e "${LOG_WARN}WARNING:${NC} aria2 is installed and FORCE_REINSTALL=true. Re-installing."
        sudo apt-get remove -y aria2 > /dev/null 2>&1 || error_exit "Failed to remove aria2 via apt-get"
        echo -e "${LOG_INFO}INFO:${NC} aria2 package removed."
    else
        ARIA_PATH=$(command -v aria2c)
        echo -e "${LOG_INFO}INFO:${NC} aria2 is already installed."
        echo -e "${LOG_INFO}INFO:${NC} PATH: ${ARIA_PATH}"
        should_install=false
    fi
fi

# --- INSTALLATION ---
if [ "$should_install" = "true" ]; then
    echo -e "${LOG_INFO}INFO:${NC} Proceeding with aria2 installation..."

    # Update package lists and install aria2
    sudo apt-get update -y > /dev/null 2>&1 || error_exit "Failed to update apt package lists"
    sudo apt-get install -y aria2 > /dev/null 2>&1 || error_exit "Failed to install aria2 via apt-get"

    echo -e "${LOG_OK}SUCCESS:${NC} aria2 installed successfully."

    # --- VERIFY PATH ---
    ARIA_PATH=$(command -v aria2c)
    if [ -z "$ARIA_PATH" ]; then
        error_exit "Installation seemed to succeed, but aria2c is not in the system PATH."
    fi

    echo -e "${LOG_INFO}INFO:${NC} aria2c PATH: ${ARIA_PATH}"
fi

exit 0

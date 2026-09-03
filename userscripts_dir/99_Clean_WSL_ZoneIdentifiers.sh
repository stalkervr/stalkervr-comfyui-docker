#!/bin/bash

# ==============================================================================
#           Clean WSL2 Zone.Identifier Files
# ==============================================================================
#
# WSL2 (Windows Subsystem for Linux) can create "Zone.Identifier" files when 
# interacting with the Windows file system. These are "Alternate Data Streams" 
# (ADS) representing Windows security metadata (e.g. "Mark of the Web").
# Inside Linux, they appear as annoying files often named "filename:Zone.Identifier".
#
# This script scans the target directory and recursively removes them.
#
# ==============================================================================

# --- CONFIGURATION ---
TARGET_DIR="/basedir"
# ---------------------

set -e

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

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo -e "!! Exiting Cleaner Script (ID: $$)"
  exit 1
}

# --- MAIN SCRIPT ---

echo "${LOG_INFO}INFO:${NC} Starting cleanup of Zone.Identifier files..."
echo " - Target: ${TARGET_DIR}"

if [ ! -d "$TARGET_DIR" ]; then
    error_exit "Target directory '${TARGET_DIR}' does not exist."
fi

# Disable 'set -e' temporarily so 'find' doesn't crash script on "Permission denied" errors
set +e

# Find files matching the WSL Identifier pattern and delete them
# -type f : Only look for files
# -name "*:Zone.Identifier" : Matches standard WSL representation
# -delete : Delete the file immediately
# -print : Print the name (so we can count them)
# 2>/dev/null : Suppress "Permission denied" error messages to keep console clean
CLEANED_COUNT=$(find "$TARGET_DIR" -type f -name "*:Zone.Identifier" -print -delete 2>/dev/null | wc -l)

# Re-enable 'set -e'
set -e

# --- SUMMARY ---
if [ "$CLEANED_COUNT" -gt 0 ]; then
    echo "${LOG_OK}SUCCESS:${NC} Cleanup complete. Removed ${CLEANED_COUNT} Zone.Identifier files."
else
    echo "${LOG_INFO}INFO:${NC} Cleanup complete. No Zone.Identifier files found."
fi

exit 0
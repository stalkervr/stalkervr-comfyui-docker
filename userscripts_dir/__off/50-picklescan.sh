#!/bin/bash

# Start the timer (using date for compatibility)
START_TIME=$(date +%s)

# Script that installs picklescan package and runs a scan.
# Picklescan is a security scanner detecting Python Pickle files (e.g. .pt files) performing suspicious actions.
# Picklescan Github has plenty of resources on the risks: https://github.com/mmaitre314/picklescan
# Since there are still so many .pt files circulating and in use (e.g. Ultralytics), they should be scanned regularly.
# 
# !!NOTE: This is a first line of defense, and isn't flawless. Best protection is to not use pickle files at all !!
#
# Outputs result to console and with commented info to a logfile in dockerscripts dir (overwrites)
#
# Can safely be kept in the userscripts dir to scan each time.
# Scans entire /basedir by default due to some custom nodes putting models in their own custom_node app directory

# --- CONFIGURATION ---
TARGET_DIR="/basedir"
SCAN_TIMEOUT=15                                 # Set timeout to your wishes; Scanning 200 files takes about 10s
FAIL_ON_THREATS="${FAIL_ON_THREATS:-true}"      # Set to false if you want to continue docker startup
FAIL_ON_WARNINGS="${FAIL_ON_WARNINGS:-false}"   # Set to true if you want to stop docker startup on nonblocking warnings
FAIL_ON_TIMEOUT="${FAIL_ON_TIMEOUT:-true}"      # Set to false if you want to proceed even if scan times out
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"     # Set to true to force reinstall of Picklescan

# Regex patterns for file/directory filtering (Requires picklescan >= 1.0.2)
# Leave empty to scan all eligible files in TARGET_DIR  recursively (default behavior)
SCAN_INCLUDE_REGEX=""       # e.g., '\.pt$' - Only scan files matching this
SCAN_EXCLUDE_REGEX=""       # e.g., '\.bin$' - Skip files matching this
SCAN_INCLUDE_DIR_REGEX=""   # Only descend into directories matching this
SCAN_EXCLUDE_DIR_REGEX=""   # e.g., 'blender' - Skip these directories

# --- PICKLESCAN MINIMUM VERSION ---
MIN_PICKLESCAN_VERSION="1.0.2" # (1.0.2 adds 'include' and 'exclude' options)
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
  echo -e "!! Exiting Picklescan Script (ID: $$)"
  exit 1
}

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

# --- CHECK EXISTING INSTALLATION & VERSION ---
should_install=true

if pip show picklescan > /dev/null 2>&1; then
    if [ "$FORCE_REINSTALL" = "true" ]; then
        echo "${LOG_WARN}WARNING:${NC} Picklescan is installed and FORCE_REINSTALL=true. Re-installing."
        pip uninstall -y picklescan || error_exit "Failed to uninstall picklescan"
        echo "${LOG_INFO}INFO:${NC} Picklescan package removed"
    else
        # Check Version
        INSTALLED_VER=$(pip show picklescan 2>/dev/null | grep Version | awk '{print $2}')
        # Sort versions: if the lowest is the MIN_VERSION, then INSTALLED >= MIN
        LOWEST=$(printf '%s\n' "$MIN_PICKLESCAN_VERSION" "$INSTALLED_VER" | sort -V | head -n1)
        
        if [ "$LOWEST" = "$MIN_PICKLESCAN_VERSION" ]; then
             echo "${LOG_INFO}INFO:${NC} Picklescan is already installed ($INSTALLED_VER >= $MIN_PICKLESCAN_VERSION)."
             should_install=false
        else
             echo "${LOG_WARN}WARNING:${NC} Installed Picklescan ($INSTALLED_VER) is older than required ($MIN_PICKLESCAN_VERSION). Updating..."
             pip uninstall -y picklescan || error_exit "Failed to uninstall old picklescan"
        fi
    fi
fi

if [ "$should_install" = "true" ]; then
    echo "${LOG_INFO}INFO:${NC} Installing Picklescan..."
    echo "== PIP3_CMD: \"${PIP3_CMD}\""
    if [ "A$use_uv" == "Atrue" ]; then
        echo "== Using uv"
        echo " - uv: $uv"
        echo " - uv_cache: $uv_cache"
    else
        echo "== Using pip"
    fi

    CMD="${PIP3_CMD} picklescan"
    echo "CMD: \"${CMD}\""
    ${CMD} > /dev/null 2>&1 || error_exit "Failed to install picklescan"
    echo "${LOG_OK}SUCCESS:${NC} Picklescan installed"
fi
# -----------------------------------

# 2. Run picklescan and log output
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/picklescan_output.txt"


echo "${LOG_INFO}== Running picklescan...${NC}"
echo " - Target: ${TARGET_DIR}"
echo " - Timeout: ${SCAN_TIMEOUT}s"
echo " - Log: ${LOG_FILE}"
echo "..."

# --- Write Header to Log File ---
cat <<EOF > "${LOG_FILE}"
# Picklescan by MMaitre314 
# Security scanner detecting Python Pickle files performing suspicious actions.
# More info: https://github.com/mmaitre314/picklescan
# Default Scanning entire basedir due to some custom nodes putting models in their own custom_node app directory
# Modify as wished. Scan is quick enough to not cause noticable downtime.
# -------------------------------------
# Scan results; Scroll to end for summary:
#
EOF

# --- Prepare Scan Arguments ---
# Build array for optional arguments to avoid quoting issues
REGEX_ARGS=()

[ -n "$SCAN_INCLUDE_REGEX" ] && REGEX_ARGS+=("--include" "$SCAN_INCLUDE_REGEX")
[ -n "$SCAN_EXCLUDE_REGEX" ] && REGEX_ARGS+=("--exclude" "$SCAN_EXCLUDE_REGEX")
[ -n "$SCAN_INCLUDE_DIR_REGEX" ] && REGEX_ARGS+=("--include-dir" "$SCAN_INCLUDE_DIR_REGEX")
[ -n "$SCAN_EXCLUDE_DIR_REGEX" ] && REGEX_ARGS+=("--exclude-dir" "$SCAN_EXCLUDE_DIR_REGEX")

# Log usage of regex to file
if [ ${#REGEX_ARGS[@]} -gt 0 ]; then
    echo "Using Filter Arguments: ${REGEX_ARGS[*]}" >> "${LOG_FILE}"
fi

# --- Run Scan , log to File ONLY (avoiding 'harmless' warning messages cluttering console) ---

# Enable pipefail: if 'timeout' fails, the whole pipe fails
set -o pipefail

# Disable 'set -e' so we can handle exit code of picklescan process manually
set +e 

# Run the main scan with a timeout
# PYTHONUNBUFFERED=1 ensures output is written to file immediately, not lost if killed.
# Redirect stdout/stderr to log file.
PYTHONUNBUFFERED=1 timeout "${SCAN_TIMEOUT}" picklescan --path "${TARGET_DIR}" "${REGEX_ARGS[@]}" >> "${LOG_FILE}" 2>&1
EXIT_CODE=$?

# Check the result
if [ $EXIT_CODE -eq 124 ]; then
    # 124 = Timeout
    
    # Write clean to log
    echo "!! Scan timed out (> ${SCAN_TIMEOUT}s)." >> "${LOG_FILE}"
    echo "!! Consider adding exclusions or extending the timeout." >> "${LOG_FILE}"
    
    # Write color to console
    echo "${LOG_WARN}WARNING:${NC} !! Scan timed out (> ${SCAN_TIMEOUT}s)."
    echo "         Check log for details. Consider adding exclusions or extending the timeout."
    
    # 3. Handle Fail on Timeout
    if [ "$FAIL_ON_TIMEOUT" = "true" ]; then
        # Write clean to log
        echo "Timeout reached and FAIL_ON_TIMEOUT is true. Exiting incomplete scan." >> "${LOG_FILE}"

        # Write color to console
        echo -e "${LOG_ERR}Timeout reached and FAIL_ON_TIMEOUT is true. Exiting incomplete scan.${NC}"
        exit 1
    else
        # Write clean to log
        echo "!! FAIL_ON_TIMEOUT is false: Proceeding with incomplete scan results..." >> "${LOG_FILE}"

        # Write color to console
        echo "${LOG_WARN}WARNING: FAIL_ON_TIMEOUT is false. Proceeding with INCOMPLETE scan results...${NC}"
    fi

elif [ $EXIT_CODE -ne 0 ] && [ $EXIT_CODE -ne 1 ]; then
    # If it failed with something other than 0 (Success) or 1 (Threats Found)
	  # Write clean to log
    echo "!! Warning: Main scan returned unusual exit code: $EXIT_CODE" >> "${LOG_FILE}"
	  # Write color to console
    echo "${LOG_WARN}WARNING:${NC} Main scan returned unusual exit code: $EXIT_CODE"
fi

# Re-enable 'set -e'
set -e
# Disable pipefail to ensure grep doesn't crash script if string not found
set +o pipefail

# --- ANALYZE RESULTS & PRINT SUMMARY TO CONSOLE ---

# Extract counts from log file (default to 0 if not found)
# We append '|| true' to ensure script doesn't exit if grep returns 1 (not found)
# This is common if scan timed out and didn't write the summary footer.
INFECTED_COUNT=$(grep "Infected files:" "${LOG_FILE}" | awk '{print $3}' || true)
GLOBALS_COUNT=$(grep "Dangerous globals:" "${LOG_FILE}" | awk '{print $3}' || true)
WARNING_COUNT=$(grep -c "WARNING:" "${LOG_FILE}" || true)

INFECTED_COUNT=${INFECTED_COUNT:-0}
GLOBALS_COUNT=${GLOBALS_COUNT:-0}
WARNING_COUNT=${WARNING_COUNT:-0}

echo "----------- SCAN SUMMARY -----------"
grep "Scanned files:" "${LOG_FILE}" || echo "Scanned files: 0"

# Print Infected Files (Red if > 0, else Green)
if [ "$INFECTED_COUNT" -gt 0 ]; then
    echo -e "${LOG_ERR}Infected files: ${INFECTED_COUNT}${NC}"
else
    echo -e "${LOG_OK}Infected files: ${INFECTED_COUNT}${NC}"
fi

# Print Dangerous Globals (Red if > 0, else Green)
if [ "$GLOBALS_COUNT" -gt 0 ]; then
    echo -e "${LOG_ERR}Dangerous globals: ${GLOBALS_COUNT}${NC}"
else
    echo -e "${LOG_OK}Dangerous globals: ${GLOBALS_COUNT}${NC}"
fi

# Print Warnings (Yellow if > 0)
if [ "$WARNING_COUNT" -gt 0 ]; then
    echo -e "${LOG_WARN}Warnings found: ${WARNING_COUNT}${NC}; Non-blocking, check output for details"
fi

# --- Calculate Duration ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$(($DURATION / 60))
SECS=$(($DURATION % 60))
TIME_MSG="Total execution time: ${MINUTES}m ${SECS}s"

# --- Append Footer to Log File ---
cat <<EOF >> "${LOG_FILE}"
# ------------------------
# ${TIME_MSG}
# You can (probably) safely ignore 'Warning: could not parse ...' messages.
# You should NOT ignore 'infected' or 'dangerous globals' messages.
# No support given on this scan script; for scan issues visit the Picklescan github.
# For Pickle issues or false positives; contact Picklescan github or offending file owner.
# See Picklescan script on how to exclude files and directories from scan.
EOF

echo "${LOG_INFO}INFO:${NC} Saved detailed Picklescan results to ${LOG_FILE}"
echo "${LOG_INFO}INFO:${NC} ${TIME_MSG}"

# --- EXIT LOGIC ---
if [ "$FAIL_ON_THREATS" = "true" ]; then
    if [ "$INFECTED_COUNT" -gt 0 ] || [ "$GLOBALS_COUNT" -gt 0 ]; then
        echo -e "${LOG_ERR}Dangerous files or globals found: Exiting${NC}"
        exit 1
    fi
fi

if [ "$FAIL_ON_WARNINGS" = "true" ]; then
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo -e "${LOG_ERR}Warnings found: Exiting${NC}"
        exit 1
    fi
fi

exit 0
#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh

# ==============================================================================
#           Install PortAudio & PyAudio for Ubuntu 24 Docker Containers
# ==============================================================================
#
# Speech and Audio ComfyUI nodes need PyAudio. (e.g. Chatterbox)
# PyAudio needs a specific config and built version of Portaudio. 
# both PortAudio and Libasound2-dev need to be APT installed.
#
# This script downloads the libasound2-dev package and PortAudio package files.
# It then configures and builds Portaudio and then installs the PyAudio python 
# package. You can manually download the Portaudio files (place the tgz file in
# the same dir as this script), or have the script download it for you. 
# You can also force reinstall, should you have a non-working Portaudio version. 
# Both options visible below in Configuration.
#
# This script is designed to be run inside your ComfyUI Docker container.
# 
# WARNING: RUN THIS SCRIPT AT YOUR OWN RISK. NO WARRANTY GIVEN. NO SUPPORT.
#
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# Set to 'true' to automatically download PortAudio if the archive is not found.
DOWNLOAD_PORTAUDIO="${DOWNLOAD_PORTAUDIO:-true}"

# Set to 'true' to remove any existing PortAudio installation before installing.
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"

# Set the path to your virtual environment's activation script.
VENV_PATH="${VENV_PATH:-/comfy/mnt/venv/bin/activate}"

# PortAudio download URLs
PORTAUDIO_URL="https://files.portaudio.com/archives/pa_stable_v190700_20210406.tgz"
PORTAUDIO_DOWNLOAD_PAGE="https://files.portaudio.com/download.html"

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

# --- Helper Functions ---

# Function to print an error message and exit.
error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo -e "!! Exiting PortAudio_PyAudio Script (ID: $$)"
  exit 1
}

# Function to print an informational message.
log_info() {
  echo "${LOG_INFO}INFO:${NC} $1"
}

# --- Main Script ---

# 0. EARLY EXIT CHECK
#    Since PyAudio requires PortAudio to install, if PyAudio is present,
#    we can assume PortAudio is also set up correctly.
if [ "$FORCE_REINSTALL" = "false" ]; then
    if [ -f "$VENV_PATH" ]; then
        log_info "Checking for existing PyAudio installation..."
        # Run check in a subshell to avoid affecting current shell environment
        if (source "$VENV_PATH" && pip3 show pyaudio &>/dev/null); then
            log_info "PyAudio is already installed (which implies PortAudio is present)."
            log_info "Skipping installation. Set FORCE_REINSTALL=true to force a rebuild."
            exit 0
        fi
        log_info "PyAudio not found. Proceeding with PortAudio installation."
    else
        log_info "Virtual environment not found at $VENV_PATH. Proceeding with installation."
    fi
else
    log_info "FORCE_REINSTALL is true. Ignoring existing PyAudio checks."
fi

# 1. Check if PortAudio needs to be installed or reinstalled.
log_info "Checking for existing PortAudio installation..."
if ldconfig -p | grep -q libportaudio && [ "$FORCE_REINSTALL" = "false" ]; then
    log_info "PortAudio library is already installed. Skipping compilation."
else
    # This block runs if PortAudio is not found OR if a reinstall is forced.
    if [ "$FORCE_REINSTALL" = "true" ]; then
        log_info "FORCE_REINSTALL is true. Attempting to clean up previous installations."
        if [ -d "/usr/src/portaudio" ]; then
            log_info "Found existing source directory. Running 'make uninstall'..."
            # Run in a subshell to avoid changing the script's directory
            (cd /usr/src/portaudio && sudo make -s uninstall > /dev/null || log_info "'make uninstall' failed or not available, continuing cleanup.")
            log_info "Removing old source directory..."
            sudo rm -rf /usr/src/portaudio
        else
            log_info "No existing source directory found at /usr/src/portaudio to uninstall from."
        fi
        log_info "Forcing update of library cache after cleanup..."
        sudo ldconfig
    fi

    log_info "Starting full PortAudio installation process."

    # 1a. Find or download the PortAudio source archive.
    log_info "Looking for PortAudio archive..."
    BASE_DIR=$(dirname "$(readlink -f "$0")")
    PA_ARCHIVE=$(find "$BASE_DIR" -maxdepth 1 -name 'pa_stable_*.tgz' | head -n 1)

    if [ -z "$PA_ARCHIVE" ]; then
      log_info "PortAudio archive not found in the script's directory."
      if [ "$DOWNLOAD_PORTAUDIO" = "true" ]; then
        log_info "Attempting to download from $PORTAUDIO_URL..."
        if ! wget -q -P "$BASE_DIR" "$PORTAUDIO_URL"; then
            error_exit "Failed to download PortAudio. Please download it manually from $PORTAUDIO_DOWNLOAD_PAGE"
        fi
        PA_ARCHIVE=$(find "$BASE_DIR" -maxdepth 1 -name 'pa_stable_*.tgz' | head -n 1)
        [ -z "$PA_ARCHIVE" ] && error_exit "Downloaded PortAudio, but could not find the archive."
        log_info "Download successful."
      else
        error_exit "DOWNLOAD_PORTAUDIO is false. Please download the PortAudio archive from $PORTAUDIO_DOWNLOAD_PAGE and place it in the same directory as this script."
      fi
    fi
    log_info "Found PortAudio archive: $PA_ARCHIVE"

    # 1b. Install required system packages.
    log_info "Updating package lists and installing libasound2-dev..."
    if ! sudo apt-get -q update || ! sudo apt-get -q install -y libasound2-dev; then
      error_exit "Failed to install required system packages."
    fi
    log_info "libasound2-dev installed successfully."

    # 1c. Extract the PortAudio source archive.
    log_info "Extracting PortAudio to /usr/src/..."
    if ! sudo tar -xzf "$PA_ARCHIVE" -C /usr/src/; then
      error_exit "Failed to extract PortAudio archive."
    fi
    log_info "Extraction complete."

    # 1d. Build and install PortAudio from source.
    log_info "Changing directory to /usr/src/portaudio..."
    cd /usr/src/portaudio || error_exit "Could not change to /usr/src/portaudio directory."

    log_info "Configuring PortAudio build..."
    # Redirect configure output to /dev/null to keep the log clean.
    CONFIGURE_OUTPUT=$(sudo ./configure > /dev/null)
    # We still need to check the summary, so we run configure again and capture its output.
    # This is a bit redundant but ensures we can check the ALSA line while keeping the main log clean.
    CONFIGURE_SUMMARY=$(sudo ./configure)
    echo "$CONFIGURE_SUMMARY"

    if ! echo "$CONFIGURE_SUMMARY" | grep -q "ALSA .* yes"; then
      error_exit "ALSA support was not enabled by the configure script. Check dependencies."
    fi
    log_info "Configuration successful with ALSA support."

    log_info "Compiling PortAudio (make)..."
    # Redirect stdout to /dev/null to hide the verbose compilation output.
    if ! sudo make -s > /dev/null; then
      error_exit "Failed to compile PortAudio with 'make'."
    fi

    log_info "Installing PortAudio (make install)..."
    # Redirect stdout here as well.
    if ! sudo make -s install > /dev/null; then
      error_exit "Failed to install PortAudio with 'make install'."
    fi

    log_info "Updating shared library cache (ldconfig)..."
    if ! sudo ldconfig; then
      error_exit "Failed to run 'ldconfig'."
    fi
    log_info "PortAudio installed successfully."
fi

# 2. Activate virtual environment and install PyAudio.

log_info "Installing PyAudio..."

source "$VENV_PATH" || error_exit "Failed to activate virtualenv"

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

# 1. Install pyaudio
CMD="${PIP3_CMD} pyaudio"
echo "CMD: \"${CMD}\""
${CMD} || error_exit "Failed to install PyAudio"

echo "${LOG_OK}SUCCESS:${NC} PortAudio / PyAudio Installation complete! ---"
exit 0
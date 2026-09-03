#!/bin/bash

# Pre-requisites (run first):
# - None (runs before 05-customnodes_fixer.sh so cloned nodes get their
#   requirements installed in the same container start)

# Clone listed custom nodes into BASE_DIRECTORY/custom_nodes if not already
# present. Designed to ensure "well-known missing" nodes are available so the
# downstream 05-customnodes_fixer.sh picks up their requirements.txt.
#
# Configure via env var CLONE_MISSING_NODES (space-separated entries of
# "<folder>|<git-url>[|<branch-or-tag>]"). If unset, the DEFAULT_NODES below
# are used. Set CLONE_MISSING_NODES="" to disable entirely.

# --- CONFIGURATION ---
# Each entry: <folder>|<git-url>[|<branch-or-tag>]
DEFAULT_NODES=(
  "comfyui_controlnet_aux|https://github.com/Fannovel16/comfyui_controlnet_aux.git"
)
CLONE_MISSING_NODES="${CLONE_MISSING_NODES-__default__}"
# ---------------------

# --- COLOR CODES (for console)---
LOG_ERR=$(printf '\033[0;41m') # White on RED BG
LOG_WARN=$(printf '\033[0;33m') # Yellow
LOG_OK=$(printf '\033[0;32m') # GREEN
LOG_INFO=$(printf '\033[0m') # No Color
NC=$(printf '\033[0m') # No Color
# --------------------------------

set -e

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo "!! Exiting clone_missing_nodes script (ID: $$)"
  exit 1
}

CUSTOM_NODES_DIR="${BASE_DIRECTORY:-/basedir}/custom_nodes"
if [ ! -d "$CUSTOM_NODES_DIR" ]; then
  error_exit "Custom nodes directory not found: $CUSTOM_NODES_DIR"
fi

if [ "$CLONE_MISSING_NODES" = "__default__" ]; then
  entries=("${DEFAULT_NODES[@]}")
  echo "${LOG_INFO}INFO:${NC} using default node list (override with CLONE_MISSING_NODES env var)"
else
  read -r -a entries <<< "$CLONE_MISSING_NODES"
fi

if [ "${#entries[@]}" -eq 0 ]; then
  echo "${LOG_INFO}INFO:${NC} CLONE_MISSING_NODES is empty, nothing to do"
  exit 0
fi

for entry in "${entries[@]}"; do
  IFS='|' read -r folder url branch <<< "$entry"
  target="$CUSTOM_NODES_DIR/$folder"

  if [ -z "$folder" ] || [ -z "$url" ]; then
    echo "${LOG_WARN}WARN:${NC} skipping malformed entry: '$entry' (expected <folder>|<url>[|<branch>])"
    continue
  fi

  if [ -d "$target" ]; then
    echo "${LOG_INFO}INFO:${NC} $folder already present, skipping clone"
    continue
  fi

  # Respect .disabled marker (user may have intentionally removed the node)
  if [ -d "$CUSTOM_NODES_DIR/.disabled/$folder" ]; then
    echo "${LOG_WARN}WARN:${NC} $folder is disabled (.disabled/$folder), skipping clone"
    continue
  fi

  echo "++ Cloning $folder from $url${branch:+ (branch/tag: $branch)}"
  clone_args=(--depth 1)
  if [ -n "$branch" ]; then
    clone_args+=(--branch "$branch")
  fi
  if git clone "${clone_args[@]}" "$url" "$target"; then
    echo "${LOG_OK}SUCCESS:${NC} cloned $folder"
  else
    echo "${LOG_ERR}FAIL:${NC} could not clone $folder (continuing)"
    rm -rf "$target"
  fi
done

exit 0

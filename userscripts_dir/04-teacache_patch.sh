#!/bin/bash

# Pre-requisites (run first):
# - 03-clone_missing_nodes.sh (only if teacache is among the cloned nodes;
#   typically teacache is pre-installed by the user)

# Workaround for https://github.com/welltop-cn/ComfyUI-TeaCache (unmaintained
# since 2025-07): the upstream node imports `precompute_freqs_cis` from
# `comfy.ldm.lightricks.model`, which was refactored into a model method in
# newer ComfyUI releases. Without this patch, teacache fails with
# `ImportError: cannot import name 'precompute_freqs_cis'`.
#
# We make the import soft (try/except, fall back to None) so teacache loads.
# All non-LTXV model paths (Flux, Wan, Hunyuan, HiDream, Lumina2, etc.) keep
# working. The LTXV teacache forward path remains upstream-broken and would
# need a real port of the new API; it will error at runtime if selected.
#
# Idempotent: re-runs are no-ops once the patch marker is present, and the
# patch is skipped entirely if the upstream symbol is restored in ComfyUI.

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
  echo "!! Exiting teacache_patch script (ID: $$)"
  exit 1
}

CUSTOM_NODES_DIR="${BASE_DIRECTORY:-/basedir}/custom_nodes"
target="$CUSTOM_NODES_DIR/teacache/nodes.py"
marker="# TEACACHE_SOFT_IMPORT_PATCH"
old_line="from comfy.ldm.lightricks.model import precompute_freqs_cis"

if [ ! -f "$target" ]; then
  echo "${LOG_INFO}INFO:${NC} teacache not installed at $target, skipping patch"
  exit 0
fi

if grep -q "$marker" "$target"; then
  echo "${LOG_INFO}INFO:${NC} teacache already patched, skipping"
  exit 0
fi

if ! grep -qF "$old_line" "$target"; then
  echo "${LOG_WARN}WARN:${NC} expected import line not found in teacache nodes.py; upstream may have changed, leaving file alone"
  exit 0
fi

# Skip patching if the upstream symbol is back (future-proof against a
# ComfyUI revert or a teacache update that uses the new API).
lightricks_model="/comfy/mnt/ComfyUI/comfy/ldm/lightricks/model.py"
if [ -f "$lightricks_model" ] && grep -qE '^def precompute_freqs_cis\b' "$lightricks_model"; then
  echo "${LOG_INFO}INFO:${NC} comfy.ldm.lightricks.model.precompute_freqs_cis is available, patch not needed"
  exit 0
fi

python3 - "$target" "$marker" <<'PY' || error_exit "Failed to apply teacache patch"
import sys, pathlib
path = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
src = path.read_text()
old = "from comfy.ldm.lightricks.model import precompute_freqs_cis"
new = (
    f"{marker}\n"
    "try:\n"
    "    from comfy.ldm.lightricks.model import precompute_freqs_cis\n"
    "except ImportError:\n"
    "    precompute_freqs_cis = None  # removed in newer ComfyUI; LTXV teacache path disabled\n"
)
if old not in src:
    raise SystemExit("expected import line not found")
path.write_text(src.replace(old, new, 1))
PY

echo "${LOG_OK}SUCCESS:${NC} patched teacache import to be soft (LTXV teacache path remains broken upstream)"
exit 0

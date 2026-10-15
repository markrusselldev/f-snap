#!/usr/bin/env bash
# undo-f-snap - remove what f-snap installed
# Copyright (C) 2025-2026  Mark David Russell
# SPDX-License-Identifier: GPL-3.0-or-later
# This program comes with ABSOLUTELY NO WARRANTY. See LICENSE for the terms.
#
# Remove the replacement apps f-snap installed, and reverse its other changes, per its log.
#
#   ./undo-f-snap.sh [--dry-run]
#
# -E so the ERR trap is inherited by functions; see the note in f-snap.sh.
set -Eeuo pipefail
trap 'echo; echo "❌ undo FAILED at line $LINENO: $BASH_COMMAND"; exit 1' ERR

LOGFILE="$(dirname "$0")/f-snap.log"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --help|-h)    echo "Usage: ./undo-f-snap.sh [--dry-run]"; exit 0 ;;
    *)            echo "❌ Unknown option: $arg"; exit 2 ;;
  esac
done

# This script only removes things, so it gets the same rehearsal the installer has.
run() {
  if ((DRY_RUN)); then
    echo "   [would run] $*"
    return 0
  fi
  "$@"
}

echo "⚙️  Undoing Snap replacement using log: $LOGFILE"
((DRY_RUN)) && echo "🧪 DRY RUN - nothing will be changed."
echo ""

if [ ! -f "$LOGFILE" ]; then
  echo "❌ Log file not found: $LOGFILE"
  exit 1
fi

declare -A ACTIONS=()
declare -A TARGETS=()
PPA_FILES=()
SUPPORT_SNAPS=()
RELOCATED=()
UU_FILE=""
ESR_REPLACED=()
FLATPAK_REMOVED=0
DISCOVER_PKG=""

# Parse the log ([app] header, then action= and target= lines)
current_app=""
while read -r line; do
  if [[ "$line" =~ ^\[(.*)\]$ ]]; then
    current_app="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^action=(.*)$ ]]; then
    ACTIONS["$current_app"]="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^target=(.*)$ ]]; then
    TARGETS["$current_app"]="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^ppa_disabled=(.*)$ ]]; then
    PPA_FILES+=("${BASH_REMATCH[1]}")
  elif [[ "$line" =~ ^support_snap_removed=(.*)$ ]]; then
    SUPPORT_SNAPS+=("${BASH_REMATCH[1]}")
  elif [[ "$line" =~ ^esr_replaced=(.*)$ ]]; then
    ESR_REPLACED+=("${BASH_REMATCH[1]}")
  elif [[ "$line" =~ ^uu_origins_file=(.*)$ ]]; then
    UU_FILE="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^relocated_store=(.*)$ ]]; then
    RELOCATED+=("${BASH_REMATCH[1]}")
  elif [[ "$line" =~ ^discover_snap_plugin_removed=(.*)$ ]]; then
    DISCOVER_PKG="${BASH_REMATCH[1]}"
  fi
done < "$LOGFILE"

if [[ ${#ACTIONS[@]} -eq 0 && ${#PPA_FILES[@]} -eq 0 && -z "$DISCOVER_PKG" && ${#SUPPORT_SNAPS[@]} -eq 0 && ${#RELOCATED[@]} -eq 0 && -z "$UU_FILE" ]]; then
  echo "ℹ️ No f-snap actions found in the log. Nothing to undo."
  exit 0
fi

# Removes only the replacement apps. Profiles/config folders are NOT touched: f-snap copies a
# snap profile only where no profile existed, and the copy is the user's data now.
for app in "${!ACTIONS[@]}"; do
  target="${TARGETS[$app]:-}"
  [ -z "$target" ] && continue
  echo "🔁 Reverting $app (removing $target)..."
  if [[ "${ACTIONS[$app]}" == "apt" ]]; then
    read -ra pkgs <<<"$target"   # a target may name several packages
    run sudo apt-get remove -y "${pkgs[@]}" || true
  elif [[ "${ACTIONS[$app]}" == "flatpak" ]]; then
    # Which installation is it in? f-snap can install into either (--install-scope), so
    # assuming one scope silently removes nothing. And it must clear EVERY scope, not the
    # first one found: running f-snap twice with different scopes leaves the same app in
    # both, and an undo that removes one copy looks like it worked while a gigabyte stays put.
    found=0
    if flatpak info --system "$target" >/dev/null 2>&1; then
      run sudo flatpak uninstall --system -y "$target" || true
      found=1
    fi
    if flatpak info --user "$target" >/dev/null 2>&1; then
      run flatpak uninstall --user -y "$target" || true
      found=1
    fi
    ((found)) || echo "   '$target' is not installed in either scope - nothing to remove."
    FLATPAK_REMOVED=1
  fi
done

# The runtimes an app pulled in stay behind after the app goes (Krita's alone are over a GB).
# --unused removes only runtimes no installed app needs, so the user's other Flatpaks keep theirs.
if ((FLATPAK_REMOVED)); then
  echo "🧹 Removing Flatpak runtimes nothing uses any more..."
  run sudo flatpak uninstall --system --unused -y || true
  run flatpak uninstall --user --unused -y || true
fi

# f-snap's own unattended-upgrades fragment: it only names the repositories f-snap added.
if [[ -n "$UU_FILE" && -f "$UU_FILE" ]]; then
  echo "🔁 Removing f-snap's automatic-updates file $UU_FILE"
  run sudo rm -f "$UU_FILE"
fi

# A disabled PPA is only renamed, so renaming it back restores it exactly.
for f in "${PPA_FILES[@]}"; do
  if [[ -f "$f.disabled" && ! -e "$f" ]]; then
    echo "🔁 Re-enabling $f"
    run sudo mv "$f.disabled" "$f"
  fi
done
# Only logs from older f-snap versions name this: f-snap no longer removes Discover's snap plugin.
if [[ -n "$DISCOVER_PKG" ]]; then
  echo "🔁 Reinstalling Discover's snap plugin ($DISCOVER_PKG)"
  run sudo apt-get install -y "$DISCOVER_PKG" </dev/null || true
fi

echo ""
if ((${#SUPPORT_SNAPS[@]})); then
  echo "ℹ️ Support snaps f-snap removed. To put them back:"
  echo "   sudo snap install ${SUPPORT_SNAPS[*]}"
fi
if ((${#ACTIONS[@]})); then
  echo "ℹ️ Snaps are not reinstalled automatically. To get one back:"
  for app in "${!ACTIONS[@]}"; do
    echo "   sudo snap install $app"
  done
fi
if ((${#ESR_REPLACED[@]})); then
  echo "ℹ️ f-snap replaced these Mozilla channel packages, which share files with the release"
  echo "   ones. To put one back after its release package is gone:"
  echo "   sudo apt-get install ${ESR_REPLACED[*]}"
fi
if ((${#RELOCATED[@]})); then
  # Moving a store back means stopping its services and copying it again: not something an
  # undo should do unasked. The apps work the same from either place.
  echo "ℹ️ Stores f-snap moved stay where they are (bind-mounted back by /etc/fstab):"
  printf '   %s\n' "${RELOCATED[@]}"
fi
if [[ -f /etc/apt/sources.list.d/mozilla.sources ]]; then
  echo "ℹ️ Mozilla repo + pin files are left in place. To remove them:"
  echo "   sudo rm /etc/apt/sources.list.d/mozilla.sources /etc/apt/preferences.d/mozilla /etc/apt/preferences.d/no-ubuntu-mozilla-snap-stubs"
fi
if [[ -f /etc/apt/sources.list.d/element-io.sources ]]; then
  echo "ℹ️ Element's repo is left in place too. To remove it:"
  echo "   sudo rm /etc/apt/sources.list.d/element-io.sources /etc/apt/keyrings/element-io-archive-keyring.gpg"
fi
echo ""
echo "✅ Undo complete."

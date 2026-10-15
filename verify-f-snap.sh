#!/bin/bash
# verify-f-snap - check what f-snap did
# Copyright (C) 2025-2026  Mark David Russell
# SPDX-License-Identifier: GPL-3.0-or-later
# This program comes with ABSOLUTELY NO WARRANTY. See LICENSE for the terms.

set -euo pipefail
LOGFILE="$(dirname "$0")/f-snap.log"
APPLIST="$(dirname "$0")/apps.conf"
LEFTOVER_DIRS=()
PROBLEMS=0

echo "🔍 Verifying f-snap migration..."
echo "Using log file: $LOGFILE"
echo ""

verify_app() {
  local app="$1"
  local method="$2"
  local config_path="$3"
  local target="$4"

  echo "📦 Verifying $app..."

  snap_out=$(snap list 2>/dev/null | grep "^$app\s" || echo "(not found)")
  echo "🔎 snap list:"
  echo "$snap_out"

  # Snap still installed
  if [[ "$snap_out" != "(not found)" ]]; then
    echo "⚠️  Snap '$app' is still installed."
  else
    echo "✔ No active Snap found for '$app'."
  fi

  # Only an app f-snap replaced has a replacement to check. Each flavor seeds a different set,
  # so an app that was never a snap here is not a failure.
  if [ -f "$LOGFILE" ] && ! grep -qx "snap_removed=$app" "$LOGFILE"; then
    echo "ℹ️ f-snap did not replace '$app' on this system - nothing more to check."
    echo ""
    return 0
  fi

  if [[ "$method" == "apt" ]]; then
    # A target can name several packages, space-separated.
    # ${db:Status-Status} is the status word on its own - "part of the Status field (since
    # dpkg 1.17.11)", man dpkg-query - rather than matching a three-word string.
    local pkg state version
    for pkg in $target; do
      state=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || echo "not installed")
      version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "-")
      echo "🔎 dpkg $pkg: $state $version"
      # An epoch'd "1:1snapN-..." version means Ubuntu's transitional package, not Mozilla's deb.
      if [[ "$state" == "installed" && "$version" != *snap* ]]; then
        echo "✅ $pkg is installed via APT (not the Snap stub)."
      else
        echo "❌ $pkg APT install not detected properly."
        PROBLEMS=$((PROBLEMS + 1))
      fi
      if [[ "$app" == firefox || "$app" == thunderbird ]]; then
        echo "🔎 apt-cache policy $pkg (should come from packages.mozilla.org):"
      else
        echo "🔎 apt-cache policy $pkg:"
      fi
      apt-cache policy "$pkg" | sed -n '2,3p'
    done
  elif [[ "$method" == "flatpak" ]]; then
    # f-snap can install per-user OR system-wide, so report WHICH store holds the app instead
    # of assuming one. `flatpak list` with no scope flag covers both installations.
    local scope
    scope=$(flatpak list --app --columns=application,installation 2>/dev/null \
            | awk -F'\t' -v id="$target" '$1==id {print $2; exit}')
    if [[ -n "$scope" ]]; then
      echo "✅ $target Flatpak is installed ($scope scope)."
    else
      echo "❌ $target Flatpak not found in either the user or system installation."
      PROBLEMS=$((PROBLEMS + 1))
    fi
  fi

  # Profile/config folder in place ("-" means the app keeps no profile to carry over)
  local alt here=""
  for alt in ${config_path//|/ }; do
    if [[ "$alt" != "-" && -d "$HOME/$alt" ]]; then here="$alt"; break; fi
  done
  if [[ "$config_path" == "-" ]]; then
    :
  elif [[ -n "$here" ]]; then
    echo "✔ Config folder present: ~/$here"
  else
    echo "ℹ️ No config folder at ~/${config_path//|/ or ~/} yet (created on first launch)."
  fi

  # Check leftover snap data
  snap_data="$HOME/snap/$app"
  if [ -d "$snap_data" ]; then
    echo "⚠️  Snap data folder still exists: $snap_data"
    LEFTOVER_DIRS+=("$snap_data")
  fi

  echo ""
}

while IFS=: read -r app method config_path target; do
  [[ "$app" =~ ^#.*$ || -z "$app" ]] && continue
  verify_app "$app" "$method" "$config_path" "$target"
done < "$APPLIST"

# Relocated stores: each must still be its bind mount, and for snapd every snap mount must have
# come up from it, which only a reboot proves.
for store in /var/lib/flatpak /var/lib/snapd; do
  if [[ "$(findmnt -rno TARGET "$store" 2>/dev/null)" == "$store" ]]; then
    echo "✅ $store is backed by $(findmnt -rno SOURCE "$store")"
    [[ -d "$store.pre-relocate" ]] && echo "   The pre-move copy $store.pre-relocate is still there; delete it once all is well."
  elif [ -f "$LOGFILE" ] && grep -q "^relocated_store=$store " "$LOGFILE"; then
    echo "❌ $store was relocated but is NOT mounted now. Check /etc/fstab and 'systemctl status $(systemd-escape -p --suffix=mount "$store")'."
    PROBLEMS=$((PROBLEMS + 1))
  fi
done
if [[ "$(findmnt -rno TARGET /var/lib/snapd 2>/dev/null)" == /var/lib/snapd ]]; then
  failed_mounts="$(systemctl list-units --failed --type=mount --plain --no-legend 2>/dev/null | awk '$1 ~ /^snap-/{print $1}' || true)"
  if [[ -n "$failed_mounts" ]]; then
    echo "❌ Snap mounts failed: $failed_mounts"
    PROBLEMS=$((PROBLEMS + 1))
  else
    echo "✅ No snap mount has failed."
  fi
  echo ""
fi

# Automatic updates: every repository f-snap added must be in unattended-upgrades' merged
# Origins-Pattern list, or the apps it installed from them stop updating.
if [ -f "$LOGFILE" ] && grep -q '^uu_origins_file=' "$LOGFILE"; then
  uu_patterns="$(apt-config dump 2>/dev/null | grep '^Unattended-Upgrade::Origins-Pattern::' || true)"
  for site in packages.mozilla.org packages.element.io; do
    [[ "$site" == packages.element.io && ! -f /etc/apt/sources.list.d/element-io.sources ]] && continue
    if grep -q "site=$site" <<<"$uu_patterns"; then
      echo "✅ Automatic updates cover $site"
    else
      echo "❌ Automatic updates do NOT cover $site - check /etc/apt/apt.conf.d/52unattended-upgrades-f-snap"
      PROBLEMS=$((PROBLEMS + 1))
    fi
  done
  echo ""
fi

# Snap configs that were found but deliberately not copied (an existing profile won)
if [ -f "$LOGFILE" ] && grep -q '^config_left_in_snap=' "$LOGFILE"; then
  echo "ℹ️ Snap configs left in place because an existing profile was kept:"
  grep '^config_left_in_snap=' "$LOGFILE" | sed 's/^config_left_in_snap=/    /' | sort -u
  echo ""
fi

# Leftover snap data: only offer deletion after the user confirms the apps open correctly
if [[ ${#LEFTOVER_DIRS[@]} -gt 0 ]]; then
  echo "⚠️  Leftover Snap directories not removed:"
  for dir in "${LEFTOVER_DIRS[@]}"; do
    echo "    $dir"
  done
  echo ""
  read -rp "❓ Have you confirmed each app opens with your correct profile and data? (y/n): " confirm_profiles || confirm_profiles=""
  if [[ "$confirm_profiles" =~ ^[Yy]$ ]]; then
    for dir in "${LEFTOVER_DIRS[@]}"; do
      read -rp "❓ Delete '$dir'? (y/n): " delete_it || delete_it=""
      if [[ "$delete_it" =~ ^[Yy]$ ]]; then
        rm -rf "$dir" && echo "✅ Removed: $dir"
      fi
    done
  else
    echo "⚠️  Skipping deletion. You may remove them manually later."
  fi
fi

echo ""
if ((PROBLEMS)); then
  echo "❌ Verification found $PROBLEMS problem(s) - see the ❌ lines above."
  exit 1
fi
echo "✔ Verifications complete: no problems found."

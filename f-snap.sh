#!/usr/bin/env bash
# f-snap - replace Ubuntu app snaps and move snap and Flatpak data off the root partition
# Copyright (C) 2025-2026  Mark David Russell
# SPDX-License-Identifier: GPL-3.0-or-later
# This program comes with ABSOLUTELY NO WARRANTY. See LICENSE for the terms.

# -E (errtrace) matters as much as -e here: without it bash does NOT inherit the ERR trap into
# shell functions, so a failure inside any function below would exit silently.
set -Eeuo pipefail
FSNAP_VERSION="1.0.1"
LOGFILE="$(dirname "$0")/f-snap.log"

APPLIST="$(dirname "$0")/apps.conf"

# Mozilla's APT repo signing key fingerprint, from support.mozilla.org
# ("Install Firefox on Linux" / "Install Thunderbird on Linux"). The uid on this key reads
# "Artifact Registry Repository Signer <...@google.com>" - that is expected, Mozilla hosts
# packages.mozilla.org on Google Artifact Registry.
MOZILLA_FPR="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"

usage() {
  cat <<'USAGE'
Usage: ./f-snap.sh [--dry-run] [--stores-only | --replace-apps]
                   [--flatpak-dir=PATH | --keep-flatpak-dir]
                   [--snapd-dir=PATH | --keep-snapd-dir] [--version] [--help]

  --stores-only        Only offer to move the snapd and Flatpak stores off the root partition;
                       replace no apps. Automatic on systems that are not Ubuntu or a flavor.
  --replace-apps       Replace the app snaps too without asking (Ubuntu and its flavors).

  --dry-run, -n        Change NOTHING. Print exactly what would happen to each app in
                       apps.conf: its current Snap/deb state, the APT candidate, whether the
                       swap is a downgrade, and apt's own simulation of the install -
                       including any package apt would remove to get there. Needs no sudo.
  --flatpak-dir=PATH   Store system Flatpak data at PATH instead of /var/lib/flatpak, by
                       moving it there and bind-mounting it back (see below). Skips the
                       interactive prompt.
  --keep-flatpak-dir   Leave Flatpak data at /var/lib/flatpak. Skips the prompt.
  --snapd-dir=PATH     Store snapd's data at PATH instead of /var/lib/snapd, by moving it
                       there and bind-mounting it back. Skips the interactive prompt.
  --keep-snapd-dir     Leave snapd's data at /var/lib/snapd. Skips the prompt.
  --keep-support-snaps Leave bases and content snaps (GNOME platform, Mesa, themes, codecs)
                       installed even when no remaining app uses them. By default f-snap
                       removes those, content snaps first, then bases; snapd always stays.
  --disable-mozillateam-ppa / --keep-mozillateam-ppa
                       Answer the offer to disable a leftover mozillateam PPA (default: disable).
  --config=PATH        Use an alternative apps.conf. Mainly for testing the pre-flight phase
                       against deliberately broken entries.
  --install-scope=X    Install apps into the "system" store (/var/lib/flatpak) or the "user"
                       store (~/.local/share/flatpak). Skips the prompt. System-wide is
                       flatpak's own default (man flatpak-install); f-snap asks because the
                       right answer depends on whether the system store is on the root
                       partition. The two stores are separate OSTree repositories, so
                       switching later means re-downloading.
  --version            Print the f-snap version.
  --help, -h           This text.

apps.conf is a catalog: f-snap replaces only the Snaps from it that are installed on this
machine, so the same catalog serves every Ubuntu flavor and every installer choice.

Flatpak app and runtime data is large and lands on the ROOT partition by default. If your
root partition is small, f-snap offers to move /var/lib/flatpak onto a roomier filesystem
and bind-mount it back at the original path, so every writer - the CLI, Discover, and the
root system-helper - keeps working unchanged.

snapd's data lands on the root partition too, and most of it is the installer's seed: a copy of
every snap the installer shipped, which snapd keeps for good. f-snap offers to move the whole of
/var/lib/snapd the same way. It takes effect fully after a reboot.

Rehearse with --dry-run on the machine you are about to migrate, BEFORE the real run.
A migration you cannot rehearse can only be tested by breaking a real machine.
USAGE
}

DRY_RUN=0
FAILED_APPS=()             # apps whose Snap was removed but whose replacement would not install
FLATPAK_DIR_CHOICE=""      # "" = ask, "keep" = leave it, otherwise the target path
SNAPD_DIR_CHOICE=""        # "" = ask, "keep" = leave it, otherwise the target path
KEEP_SUPPORT_SNAPS=0       # 1 = leave unused bases and content snaps installed
PPA_CHOICE=""              # "" = ask, "disable" or "keep" the mozillateam PPA
INSTALL_SCOPE_CHOICE=""    # "" = ask, else "user" or "system"
MODE_CHOICE=""             # "" = ask, "stores" (--stores-only) or "apps" (--replace-apps)
STORES_ONLY=0              # 1 = move the stores only, replace no apps
FLATPAK_SCOPE=""           # resolved to --user or --system by choose_install_scope
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)       DRY_RUN=1 ;;
    --flatpak-dir=*)    FLATPAK_DIR_CHOICE="${arg#*=}" ;;
    --keep-flatpak-dir) FLATPAK_DIR_CHOICE="keep" ;;
    --snapd-dir=*)      SNAPD_DIR_CHOICE="${arg#*=}" ;;
    --keep-snapd-dir)   SNAPD_DIR_CHOICE="keep" ;;
    --keep-support-snaps) KEEP_SUPPORT_SNAPS=1 ;;
    --disable-mozillateam-ppa) PPA_CHOICE="disable" ;;
    --keep-mozillateam-ppa)    PPA_CHOICE="keep" ;;
    --config=*)         APPLIST="${arg#*=}"
                        [[ -r "$APPLIST" ]] || { echo "❌ Cannot read config: $APPLIST"; exit 2; } ;;
    --stores-only)      MODE_CHOICE="stores" ;;
    --replace-apps)     MODE_CHOICE="apps" ;;
    --install-scope=*)  INSTALL_SCOPE_CHOICE="${arg#*=}"
                        case "$INSTALL_SCOPE_CHOICE" in
                          user|system) ;;
                          *) echo "❌ --install-scope must be 'user' or 'system'."; exit 2 ;;
                        esac ;;
    --version)          echo "f-snap $FSNAP_VERSION"; exit 0 ;;
    --help|-h)          usage; exit 0 ;;
    *)                  echo "❌ Unknown option: $arg"; echo; usage; exit 2 ;;
  esac
done

log() { ((DRY_RUN)) && return 0; printf '%s\n' "$*" >> "$LOGFILE"; }

# Every command that CHANGES the system goes through run(), so --dry-run can print the plan
# instead of performing it.
run() {
  if ((DRY_RUN)); then
    echo "   [would run] $*"
    return 0
  fi
  "$@"
}

# Write stdin to a root-owned file, or in a dry run show the path and the EXACT content that
# would be written. The content is never described in prose: a dry run that paraphrases what
# the real run does is a dry run that can lie about it.
write_root_file() {
  local path="$1" content
  content="$(cat)"
  if ((DRY_RUN)); then
    echo "   [would write] $path"
    printf '%s\n' "$content" | sed 's/^/        | /'
    return 0
  fi
  printf '%s\n' "$content" | sudo tee "$path" >/dev/null
}

if ((DRY_RUN)); then
  echo -e "\n🧪 DRY RUN - nothing will be changed."
else
  echo -e "\n--- Run started at $(date) ---\n" >> "$LOGFILE"
  echo -e "\n🧠 Starting f-snap..."
  log "Timestamp: $(date)"
  log "f-snap version: $FSNAP_VERSION"
fi

# Fail LOUDLY and on the record: every failure is logged with its line, command and exit code.
# A failure mid-migration can leave a Snap removed and its replacement not installed, and the
# terminal may be closed afterwards, so the log is the only place that state can be found.
on_err() {
  local exit_code="$1" line="$2" cmd="$3"
  echo ""
  echo "❌ f-snap FAILED at line $line (exit $exit_code): $cmd"
  echo "   Log: $LOGFILE"
  log "RUN FAILED line=$line exit=$exit_code cmd=$cmd"
  # Exit explicitly. An ERR trap only reports; without this, a failure inside a command
  # substitution kills just that subshell and the run carries on past its own error notice.
  exit "$exit_code"
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# Establish sudo up front, so the password prompt happens before anything is changed rather
# than mid-migration where a timeout would abort between removing a Snap and installing its
# replacement. Three cases, in order:
#   1. sudo already works without a prompt (cached timestamp, or NOPASSWD) - nothing to do.
#   2. there is a terminal - validate now and take the prompt here.
#   3. no terminal and no passwordless sudo - stop, because sudo cannot ask.
# `sudo -v` alone is wrong for case 1 under sudo-rs (Ubuntu 26.04's default sudo): it fails
# with "A terminal is required to authenticate" even when NOPASSWD applies, which makes the
# whole script unusable over ssh or in CI. Observed on 26.04 with sudo-rs 0.2.13.
if ((DRY_RUN)); then
  echo "   (dry run: no sudo needed)"
elif sudo -n true 2>/dev/null; then
  echo -e "\n🔐 sudo is already available without a prompt."
elif [[ -t 0 ]]; then
  echo -e "\n🔐 Checking for sudo access (you may be prompted once)..."
  sudo -v
else
  echo "❌ sudo needs a password, but there is no terminal to ask on."
  echo "   Run f-snap from a terminal, or arrange passwordless sudo for this run."
  exit 1
fi

# apps.conf is a catalog of replacements, not a to-do list: f-snap replaces only the Snaps that
# are actually installed. Which apps an installer seeds differs by flavor, and on the Calamares
# flavors (Kubuntu, Lubuntu, Unity) by which optional checkboxes were ticked, so the installed
# set is the only reliable answer. Read once: snap list needs no root.
INSTALLED_SNAPS="$(snap list 2>/dev/null | awk 'NR>1{print $1}' || true)"
snap_present() { grep -qx "$1" <<<"$INSTALLED_SNAPS"; }

# Two jobs, chosen up front: move the snapd and Flatpak stores off the root partition, and
# replace app snaps. The replacements (Mozilla's and Element's repositories, Ubuntu's stub
# packages, the per-app research) are built and tested for Ubuntu and its flavors, which all
# report ID=ubuntu in /etc/os-release. Elsewhere - Debian, Mint, Pop!_OS - the distribution has
# its own Firefox and its own ideas, so f-snap only moves stores there.
APP_SNAPS=()
while IFS=: read -r app _ _ _ <&3; do
  [[ "$app" =~ ^#.*$ || -z "$app" ]] && continue
  if snap_present "$app"; then APP_SNAPS+=("$app"); fi
done 3< "$APPLIST"
OS_ID="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release 2>/dev/null || true)"

choose_mode() {
  local ans
  if [[ "$OS_ID" != "ubuntu" ]]; then
    echo -e "\n🧭 This is ${OS_ID:-an unknown system}, not Ubuntu: f-snap only moves the snapd and Flatpak"
    echo "   stores here. Its app replacements are built and tested for Ubuntu and its flavors."
    STORES_ONLY=1
    return 0
  fi
  case "$MODE_CHOICE" in
    stores) echo -e "\n🧭 Moving stores only (--stores-only); no apps are replaced."; STORES_ONLY=1; return 0 ;;
    apps)   return 0 ;;
  esac
  ((${#APP_SNAPS[@]})) || return 0
  echo -e "\n🧭 App snaps f-snap can replace: ${APP_SNAPS[*]}"
  if ((DRY_RUN)); then
    echo "   (dry run: the real run asks whether to replace them, default yes. --stores-only skips them.)"
    return 0
  fi
  read -rp "   Replace them? No moves only the snapd and Flatpak stores. [Y/n]: " ans || ans=""
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    echo "   Moving stores only; no apps are replaced."
    STORES_ONLY=1
  fi
  return 0
}
choose_mode

# Refuse to run while a Snap app from the list is open
((STORES_ONLY)) || while IFS=: read -r app method config_path target <&3; do
  [[ "$app" =~ ^#.*$ || -z "$app" ]] && continue
  if pgrep -f "/snap/$app/" >/dev/null 2>&1; then
    if ((DRY_RUN)); then
      echo "⚠️ Snap '$app' is running: the real run will refuse until it is closed."
    else
      echo "❌ Snap '$app' is running. Close it and run f-snap again."
      exit 1
    fi
  fi
done 3< "$APPLIST"

# Nearest existing ancestor of a path - so we can ask which filesystem a not-yet-created
# directory would land on.
existing_parent() {
  local p="$1"
  while [[ ! -d "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  printf '%s' "$p"
}

# Which filesystem holds a path - resolving to the nearest existing ancestor first, and never
# failing. /var/lib/flatpak does not exist until flatpak is installed, and df on a missing path
# exits non-zero: inside a command substitution that trips the ERR trap and prints a failure
# notice while the run carries on regardless.
fs_of() {
  local p
  p="$(existing_parent "$1")"
  df -P "$p" 2>/dev/null | awk 'NR==2{print $1}' || true
}

# Move a system store directory onto another filesystem and bind-mount it back at its
# original path, so EVERY writer keeps working unchanged: the CLI, the GUI store (Discover),
# and the root helper daemon.
#
# This is the tool for a program that has no "keep your data here" setting of its own.
# Flatpak is one: `man flatpak` states the system installation /var/lib/flatpak "is always
# considered the default one unless overridden", and a custom installation defined in
# /etc/flatpak/installations.d does NOT become the default - so Discover would carry on
# filling the root partition however carefully the CLI is driven.
#
# A program that DOES have the setting should use it instead of this: Docker has data-root in
# /etc/docker/daemon.json, plus containerd's own root in /etc/containerd/config.toml, and
# those are vendor-supported. Reach for a bind mount only when there is no such knob.
#
# Every service named after the paths is stopped for the copy, if running, and started again
# once the mount is in place.
relocate_store() {
  local src="$1" target="$2"; shift 2
  local services=("$@") stopped=() s
  local aside="${src}.pre-relocate" probe need avail

  if [[ "$(findmnt -rno TARGET "$src" 2>/dev/null)" == "$src" ]]; then
    echo "✔ $src is already a mount point (source: $(findmnt -rno SOURCE "$src" 2>/dev/null)) - leaving it."
    return 0
  fi
  [[ "$target" == /* ]] || { echo "❌ '$target' is not an absolute path."; return 1; }
  if [[ "$target" =~ [[:space:]] ]]; then
    echo "❌ '$target' contains whitespace, which /etc/fstab cannot express safely."
    return 1
  fi
  if [[ "$target" == "$HOME" || "$target" == "$HOME"/* ]]; then
    echo "⚠️ $target sits inside your home folder, so backup tools will sweep it up."
    echo "   A sibling instead (e.g. /home/flatpak) is on the same disk but outside backups."
  fi

  probe="$(existing_parent "$target")"
  if [[ "$(fs_of "$probe")" == "$(fs_of "$src")" ]]; then
    echo "❌ $target is on the same filesystem as $src ($(fs_of "$src")). That would free nothing."
    return 1
  fi

  # Some subdirectories are root-only, so an unprivileged du (the dry run) reports a partial
  # size and exits non-zero; neither may trip the ERR trap.
  if ((DRY_RUN)); then
    need="$(du -sxB1 "$src" 2>/dev/null | cut -f1 || true)"
  else
    need="$(sudo du -sxB1 "$src" 2>/dev/null | cut -f1 || true)"
  fi
  need="${need:-0}"
  avail="$(df -PB1 "$probe" 2>/dev/null | awk 'NR==2{print $4}')"; avail="${avail:-0}"
  if (( avail < need + 1073741824 )); then   # keep a GiB of headroom
    echo "❌ Not enough room on $(fs_of "$probe"): need $((need/1024/1024)) MiB plus headroom, have $((avail/1024/1024)) MiB."
    return 1
  fi

  echo "🚚 Moving $src to $target, bind-mounted back at $src"
  for s in "${services[@]}"; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      run sudo systemctl stop "$s"
      stopped+=("$s")
    fi
  done
  run sudo mkdir -p "$target"
  run sudo rsync -aHAX --numeric-ids "$src/" "$target/"
  # The original is renamed, never deleted: if the mount fails, the data is still right there.
  run sudo mv "$src" "$aside"
  run sudo mkdir -p "$src"

  if grep -qsE "^[^#]*[[:space:]]${src}[[:space:]]" /etc/fstab; then
    echo "   /etc/fstab already has an entry for $src - not adding another."
  elif ((DRY_RUN)); then
    echo "   [would append to /etc/fstab] $target $src none bind,x-systemd.requires-mounts-for=$target 0 0"
  else
    printf '%s %s none bind,x-systemd.requires-mounts-for=%s 0 0\n' \
      "$target" "$src" "$target" | sudo tee -a /etc/fstab >/dev/null
  fi

  run sudo systemctl daemon-reload
  run sudo mount "$src"

  if ((DRY_RUN)); then
    echo "   [dry run] would then verify the mount and that the contents arrived"
    for s in "${stopped[@]}"; do
      run sudo systemctl start "$s"
    done
    return 0
  fi
  if [[ "$(findmnt -rno TARGET "$src" 2>/dev/null)" != "$src" ]]; then
    echo "❌ $src did not mount. Your data is untouched at $aside. Put it back with:"
    echo "     sudo rmdir $src && sudo mv $aside $src"
    echo "   and remove the line naming $src from /etc/fstab."
    return 1
  fi
  echo "✅ $src is now backed by $target"
  log "relocated_store=$src -> $target"
  for s in "${stopped[@]}"; do
    run sudo systemctl start "$s"
  done
  echo "   The pre-move copy is kept at $aside. Delete it once you are happy:"
  echo "     sudo rm -rf $aside"
}

# Flatpak keeps TWO separate stores and f-snap must be explicit about which one it is asking
# about: a vague "where should Flatpak data live" prompt can move one store while the apps go
# into the other, filling the store the user meant to keep small.
#
#   SYSTEM   /var/lib/flatpak            <- Discover and `flatpak install --system`; on /
#   PER-USER ~/.local/share/flatpak      <- `flatpak install --user`; inside the home folder
#
# The move must happen BEFORE anything is installed into the store, so it is asked up front.
# Asked whenever Flatpak is on the machine or this run brings it in, however it got there: a
# Flatpak someone installed themselves fills the root partition just the same. Sets
# FLATPAK_DIR_CHOICE to "keep" or the target path.
ask_flatpak_move() {
  local src="/var/lib/flatpak" default="/home/flatpak" ans

  # Already relocated on an earlier run? Say so and ask nothing - offering to move a store
  # that is already moved reads as though the first run did not take.
  if [[ "$(findmnt -rno TARGET "$src" 2>/dev/null)" == "$src" ]]; then
    echo ""
    echo "✔ SYSTEM Flatpak store already relocated: $src is backed by $(findmnt -rno SOURCE "$src" 2>/dev/null)"
    FLATPAK_DIR_CHOICE="keep"
    return 0
  fi

  echo ""
  echo "💾 SYSTEM Flatpak store: $src, on $(fs_of "$src")"
  echo "   Used by the software store (Discover, GNOME Software) and 'flatpak install'."
  echo "   Per-user installs go to $HOME/.local/share/flatpak instead, already on the"
  echo "   home filesystem. Exclude that path from your backups; its contents are rebuildable."
  df -h "$(existing_parent "$src")" 2>/dev/null | awk 'NR==2{printf "   %s free of %s there\n", $4, $2}' || true

  case "$FLATPAK_DIR_CHOICE" in
    keep) echo "   Leaving it there (--keep-flatpak-dir)."; return 0 ;;
    "") ;;
    *) echo "   Will move it to $FLATPAK_DIR_CHOICE before anything is installed into it."; return 0 ;;
  esac

  if ((DRY_RUN)); then
    echo "   (dry run: the real run offers to move this; default $default.)"
    echo "   To rehearse the move itself: ./f-snap.sh --dry-run --flatpak-dir=$default"
    FLATPAK_DIR_CHOICE="keep"
    return 0
  fi
  echo "   It can be moved to a roomier filesystem and bind-mounted back, so the software store,"
  echo "   the CLI and the root system-helper all carry on using $src unchanged."
  read -rp "   Move the SYSTEM Flatpak store? [y/N]: " ans || ans=""
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "   Leaving it at $src."
    FLATPAK_DIR_CHOICE="keep"
    return 0
  fi
  read -rp "   Store it at [$default]: " FLATPAK_DIR_CHOICE || FLATPAK_DIR_CHOICE=""
  FLATPAK_DIR_CHOICE="${FLATPAK_DIR_CHOICE:-$default}"
  echo "   Will move it to $FLATPAK_DIR_CHOICE before anything is installed into it."
}

# Runs at the first point the store exists: right after flatpak is installed when Flatpak apps
# follow, otherwise at the end, after an APT replacement may have pulled flatpak in.
FLATPAK_MOVE_DONE=0
relocate_flatpak_if_wanted() {
  [[ "$FLATPAK_DIR_CHOICE" == "keep" || -z "$FLATPAK_DIR_CHOICE" ]] && return 0
  ((FLATPAK_MOVE_DONE)) && return 0
  FLATPAK_MOVE_DONE=1
  if ! ((DRY_RUN)) && [[ ! -d /var/lib/flatpak ]]; then
    echo ""
    echo "ℹ️ Flatpak was not installed after all, so there is no store to move."
    return 0
  fi
  echo ""
  relocate_store /var/lib/flatpak "$FLATPAK_DIR_CHOICE" flatpak-system-helper
}

# snapd has no setting for where it keeps its data, so the whole of /var/lib/snapd moves, by the
# same bind mount. Three constraints decide the shape (sources: snapd and systemd, see the comments below):
#   - The bulk is seed/, the installer's copy of every snap it shipped. snapd does not support
#     modifying it, and refresh.retain does not trim it, so it can only be moved, never deleted.
#   - snaps/ alone cannot move: snapd hardlinks each download between snaps/ and cache/, and a
#     hardlink cannot cross filesystems. Seeded revisions also share inodes with seed/snaps.
#   - Each snap is a systemd mount of a .snap file in snaps/. systemd orders a loop mount after
#     the mounts its source file needs (src/core/mount.c, mount_add_mount_dependencies), so
#     every snap mount waits for the bind mount at boot with no extra configuration.
# Snaps already running keep working: their loop devices hold the original files, which stay
# in the .pre-relocate copy until a reboot switches every mount over.

# Asked up front, before the Flatpak questions, so every storage decision is made before
# anything changes; the move itself runs at the end, after the apps are replaced, when fewer
# snaps are mounted. Sets SNAPD_DIR_CHOICE to "keep" or the target path.
ask_snapd_move() {
  local src="/var/lib/snapd" default="/home/snapd" ans seed

  [[ -d "$src" ]] || { SNAPD_DIR_CHOICE="keep"; return 0; }
  if [[ "$(findmnt -rno TARGET "$src" 2>/dev/null)" == "$src" ]]; then
    echo ""
    echo "✔ snapd's data already relocated: $src is backed by $(findmnt -rno SOURCE "$src" 2>/dev/null)"
    SNAPD_DIR_CHOICE="keep"
    return 0
  fi

  seed="$(du -sh "$src/seed" 2>/dev/null | cut -f1 || true)"
  echo ""
  echo "💾 snapd's data: $src, on $(fs_of "$src")"
  echo "   The installer's seed copies alone take ${seed:-an unknown amount} there. snapd does not"
  echo "   support deleting them, but the whole directory can move to a roomier filesystem."
  df -h "$(existing_parent "$src")" 2>/dev/null | awk 'NR==2{printf "   %s free of %s there\n", $4, $2}' || true

  case "$SNAPD_DIR_CHOICE" in
    keep) echo "   Leaving it there (--keep-snapd-dir)."; return 0 ;;
    "") ;;
    *) echo "   Will move it to $SNAPD_DIR_CHOICE after the apps are replaced."; return 0 ;;
  esac

  if ((DRY_RUN)); then
    echo "   (dry run: the real run offers to move this; default $default.)"
    echo "   To rehearse the move itself: ./f-snap.sh --dry-run --snapd-dir=$default"
    SNAPD_DIR_CHOICE="keep"
    return 0
  fi
  echo "   It can be moved and bind-mounted back, so snapd and every snap keep using $src."
  echo "   Snaps that are running keep running; everything switches over at the next reboot."
  read -rp "   Move snapd's data? [y/N]: " ans || ans=""
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "   Leaving it at $src."
    SNAPD_DIR_CHOICE="keep"
    return 0
  fi
  read -rp "   Store it at [$default]: " SNAPD_DIR_CHOICE || SNAPD_DIR_CHOICE=""
  SNAPD_DIR_CHOICE="${SNAPD_DIR_CHOICE:-$default}"
  echo "   Will move it to $SNAPD_DIR_CHOICE after the apps are replaced."
}

relocate_snapd_if_wanted() {
  [[ "$SNAPD_DIR_CHOICE" == "keep" || -z "$SNAPD_DIR_CHOICE" ]] && return 0
  echo ""
  relocate_store /var/lib/snapd "$SNAPD_DIR_CHOICE" snapd.socket snapd.service
  echo "   Reboot before deleting it: running snaps keep using the pre-move copy until then."
  echo "   After the reboot, check 'snap list' and open a snap app first."
}

# Which store do the apps themselves go into? This has to be asked, because the right answer
# depends on an answer given moments earlier.
#
# `man flatpak-install`: "Unless overridden with the --user or the --installation option, this
# command installs the application or runtime in the default system-wide installation." So
# system-wide is flatpak's OWN default, and installing per-user is the deviation. The reason to
# deviate is that the system store is /var/lib/flatpak, on the root partition. Once that store
# has been moved off the root partition, the reason is gone and per-user installs quietly undo
# the relocation the user just chose.
#
# The two stores are separate OSTree repositories, so nothing is shared between them: picking
# one is a real decision, not a formality, and switching later means re-downloading.
choose_install_scope() {
  local sys_fs root_fs default choice="$INSTALL_SCOPE_CHOICE" ans
  sys_fs="$(fs_of /var/lib/flatpak)"
  root_fs="$(fs_of /)"

  if [[ "$sys_fs" == "$root_fs" ]]; then
    default="user"
  else
    default="system"
  fi

  echo ""
  echo "📍 Where should the apps themselves be installed?"
  if [[ "$default" == "system" ]]; then
    echo "   The system store is on $sys_fs, which is NOT the root partition, so 'system'"
    echo "   (flatpak's own default) puts apps there - and Discover agrees by default."
  else
    echo "   The system store is on $sys_fs, the same filesystem as /, so 'user' keeps apps"
    echo "   off the root partition in $HOME/.local/share/flatpak."
  fi

  if [[ -z "$choice" ]]; then
    if ((DRY_RUN)); then
      choice="$default"
      echo "   (dry run: would use '$choice'. Override with --install-scope=user|system.)"
    else
      read -rp "   Install scope - system or user? [$default]: " ans || ans=""
      choice="${ans:-$default}"
      until [[ "$choice" == "user" || "$choice" == "system" ]]; do
        read -rp "   Please answer 'system' or 'user' [$default]: " ans || ans=""
        choice="${ans:-$default}"
      done
    fi
  fi

  FLATPAK_SCOPE="--$choice"
  echo "   Using $FLATPAK_SCOPE for Flatpak apps and the flathub remote."
}

# Run a flatpak command in the chosen scope. System-wide changes are done through sudo rather
# than relying on a polkit prompt, so this works the same in a plain terminal and over ssh.
flatpak_scoped() {
  local sub="$1"; shift
  if [[ "$FLATPAK_SCOPE" == "--system" ]]; then
    run sudo flatpak "$sub" --system "$@"
  else
    run flatpak "$sub" --user "$@"
  fi
}

# Deliberately NOT offered: relocating the PER-USER store (~/.local/share/flatpak). It is
# already on the home filesystem, so the only thing a move would buy is sitting outside the
# home FOLDER so backup tools skip it - and a backup exclude rule does that with one line of
# config instead of a bind mount and an fstab entry for user-owned data. Prompting for a
# location would be a false choice. Exclude ~/.local/share/flatpak from your backups instead;
# everything in it is rebuildable with `flatpak install`.

# Only set Flatpak up if apps.conf actually asks for a Flatpak. Installing Flatpak, a store
# backend and a Flathub remote on a machine whose config is pure APT is work nobody asked for.
# FLATPAK_COMING also counts an APT replacement that brings flatpak in, such as GNOME Software's
# Flatpak plugin; a package named for flatpak is the signal.
HAVE_FLATPAK_APPS=0
FLATPAK_COMING=0
((STORES_ONLY)) || while IFS=: read -r app method _ target <&3; do
  [[ "$app" =~ ^#.*$ || -z "$app" ]] && continue
  snap_present "$app" || continue
  [[ "$method" == "flatpak" ]] && HAVE_FLATPAK_APPS=1
  [[ "$method" == "apt" && " $target " == *flatpak* ]] && FLATPAK_COMING=1
done 3< "$APPLIST"

if command -v snap >/dev/null 2>&1; then
  ask_snapd_move
fi
if command -v flatpak >/dev/null 2>&1 || ((HAVE_FLATPAK_APPS || FLATPAK_COMING)); then
  ask_flatpak_move
fi

# Stores only: move what was chosen above and stop. Nothing below this runs.
if ((STORES_ONLY)); then
  relocate_flatpak_if_wanted
  if command -v snap >/dev/null 2>&1; then relocate_snapd_if_wanted; fi
  if ((DRY_RUN)); then
    echo -e "\n🧪 DRY RUN finished. Nothing was changed."
  else
    log "RUN COMPLETE (stores only)"
    echo -e "\n✅ Done: stores only. Log: $LOGFILE"
  fi
  exit 0
fi

if ((HAVE_FLATPAK_APPS)); then

# Ensure Flatpak + Flathub, with the store plugin for the current desktop.
# On KDE, never install gnome-software-plugin-flatpak: it pulls in gnome-software ->
# software-properties-gtk -> gnome-keyring, which fights KDE Wallet (double password prompts).
echo -e "\n📦 Ensuring Flatpak + Flathub setup..."
run sudo apt-get update -qq
if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; then
  run sudo apt-get install -y flatpak plasma-discover-backend-flatpak kde-config-flatpak
elif [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
  run sudo apt-get install -y flatpak gnome-software-plugin-flatpak
else
  run sudo apt-get install -y flatpak
fi
# Move the SYSTEM Flatpak store off the root partition if the user wants that, BEFORE anything
# is installed into it.
relocate_flatpak_if_wanted
choose_install_scope

# Remotes are per-installation ("Unless overridden with the --user or --installation options,
# this command changes the default system-wide installation" - man flatpak-remote-add), so the
# remote has to be added in the same scope the apps will be installed into.
flatpak_scoped remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

else
  echo -e "\n📦 No Flatpak apps to install - skipping the Flathub setup."
  FLATPAK_SCOPE="--user"   # nothing will use it, but keep it defined for set -u
fi

# Mozilla's own APT repo (Firefox + Thunderbird), the method Mozilla labels "recommended". Only
# when this run swaps one of them: on a machine with neither snap there is nothing to replace,
# and the pins below would still block Ubuntu's own firefox/thunderbird packages.
NEED_MOZILLA=0
for a in firefox thunderbird; do
  if snap_present "$a" && grep -q "^$a:apt:" "$APPLIST"; then NEED_MOZILLA=1; fi
done
if ((NEED_MOZILLA)); then
echo -e "\n🌐 Setting up Mozilla's APT repository..."
# A mozillateam PPA left from an older setup is a second source for the same packages. The pins
# below make packages.mozilla.org win anyway, so it only adds confusion. It is disabled, not
# deleted: apt silently skips files ending in .disabled (apt-config: Dir::Ignore-Files-Silently),
# so renaming the file back undoes it.
disable_mozillateam_ppa() {
  local f files=() ans
  # Old guides for the PPA also had an apt.conf.d fragment letting unattended-upgrades take it
  # (often 51unattended-upgrades-firefox); it goes with the PPA. apt skips .disabled there too.
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources /etc/apt/apt.conf.d/*; do
    [[ -f "$f" && "$f" != *.disabled ]] && grep -qs 'mozillateam' "$f" && files+=("$f")
  done
  ((${#files[@]})) || return 0
  echo "⚠️ The mozillateam PPA is still configured: ${files[*]}"
  echo "   packages.mozilla.org replaces it; two Mozilla sources is one too many."
  case "$PPA_CHOICE" in
    keep) echo "   Leaving it (--keep-mozillateam-ppa)."; return 0 ;;
    disable) ;;
    *)
      if ((DRY_RUN)); then
        echo "   (dry run: the real run offers to disable it, default yes. If you answer yes:)"
      else
        read -rp "   Disable it (renamed to .disabled, reversible)? [Y/n]: " ans || ans=""
        [[ "$ans" =~ ^[Nn]$ ]] && { echo "   Leaving it."; return 0; }
      fi ;;
  esac
  for f in "${files[@]}"; do
    run sudo mv "$f" "$f.disabled"
    log "ppa_disabled=$f"
  done
}
disable_mozillateam_ppa
# Fetch to a temp file and verify the fingerprint BEFORE installing it as a trusted keyring.
# Installing first and checking afterwards leaves an unverified key in /etc/apt/keyrings when
# the check fails. The download and the check are read-only, so a dry run does them for real -
# which also proves the key is still fetchable and still the expected one.
KEYFILE="$(mktemp)"
trap 'rm -f "$KEYFILE"' EXIT
if ! wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O "$KEYFILE"; then
  echo "❌ Could not download Mozilla's signing key. Stopping."
  exit 1
fi
# --show-keys is the documented shortcut for --import --import-options show-only, and man gpg:
# "As usual for automated processing, this command should be combined with the option
# --with-colons." Match the fpr: field rather than grepping human-readable output.
if ! gpg -q --show-keys --with-colons "$KEYFILE" 2>/dev/null \
     | awk -F: -v fpr="$MOZILLA_FPR" '$1=="fpr" && $10==fpr {found=1} END{exit !found}'; then
  echo "❌ Mozilla signing key fingerprint does not match $MOZILLA_FPR. Stopping."
  exit 1
fi
echo "✔ Mozilla signing key fingerprint matches $MOZILLA_FPR"
# /etc/apt/keyrings is where man 5 sources.list says operator-managed keyrings belong
# (/usr/share/keyrings is for package-managed ones). Mode 0644 matters: the same page requires
# keyrings to be "accessible and readable for the _apt system user".
run sudo install -d -m 0755 /etc/apt/keyrings
run sudo install -m 0644 "$KEYFILE" /etc/apt/keyrings/packages.mozilla.org.asc

# ONE sources file with BOTH suites. Mozilla's Firefox and Thunderbird pages each write this
# same file with only their own suite, so following both pages silently drops one.
write_root_file /etc/apt/sources.list.d/mozilla.sources <<EOF
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla thunderbird-deb
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF

# Apply apt pinning, in two SEPARATE files. Mozilla's Firefox page writes its "block Ubuntu's
# snap firefox" pin into the same file as the priority-1000 pin, overwriting it.
echo -e "\n📌 Applying APT pinning for Firefox/Thunderbird..."
# "origin" here matches a HOSTNAME, not a Release file's Origin: field (man 5 apt_preferences
# spells out that distinction); the documented form quotes it. Priority 1000 is what lets apt
# pick Mozilla's version over the epoch'd stub, and -1 is what stops the stub coming back
# ("P < 0 prevents the version from being installed", same page).
write_root_file /etc/apt/preferences.d/mozilla <<EOF
Package: *
Pin: origin "packages.mozilla.org"
Pin-Priority: 1000
EOF
write_root_file /etc/apt/preferences.d/no-ubuntu-mozilla-snap-stubs <<EOF
Package: firefox* thunderbird*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF
run sudo rm -f /etc/apt/preferences.d/mozilla-firefox   # pin file from older f-snap versions (PPA)
else
  echo -e "\n🌐 No Firefox or Thunderbird snap to replace - Mozilla's repository is not needed."
fi

# Element's own APT repository, only when the Element snap is here and apps.conf maps it to APT.
# Element's download page gives the repository and the key URL but no fingerprint, so the key
# is fetched over HTTPS from packages.element.io as Element instructs, and checked to be a key.
# It goes in /etc/apt/keyrings like Mozilla's (operator-managed keyrings, man 5 sources.list).
if snap_present element-desktop && grep -q '^element-desktop:apt:' "$APPLIST"; then
  echo -e "\n🌐 Setting up Element's APT repository..."
  ELEMENT_KEY="$(mktemp)"
  if ! wget -q https://packages.element.io/debian/element-io-archive-keyring.gpg -O "$ELEMENT_KEY" \
     || ! gpg -q --show-keys "$ELEMENT_KEY" >/dev/null 2>&1; then
    rm -f "$ELEMENT_KEY"
    echo "❌ Could not fetch a valid Element signing key. Stopping."
    exit 1
  fi
  run sudo install -m 0644 "$ELEMENT_KEY" /etc/apt/keyrings/element-io-archive-keyring.gpg
  rm -f "$ELEMENT_KEY"
  write_root_file /etc/apt/sources.list.d/element-io.sources <<SOURCES
Types: deb
URIs: https://packages.element.io/debian/
Suites: default
Components: main
Signed-By: /etc/apt/keyrings/element-io-archive-keyring.gpg
SOURCES
fi

# Snaps refresh themselves; debs from a vendor repository do not, unless unattended-upgrades is
# told about it: "Just adding another package repository to an Ubuntu system WILL NOT make
# unattended-upgrades consider it for updates!" (Ubuntu Server docs, Automatic updates). Without
# this the swap would quietly stop updates. f-snap owns one fragment, named to sort after
# 50unattended-upgrades as the unattended-upgrades README advises, listing only the repositories
# f-snap adds. apt merges a list from every fragment (man apt.conf), so a user's own
# 52unattended-upgrades-local is never touched. Matched by site: Mozilla's origin field is an
# internal storage path, the host name is what stays stable.
# A repository counts if this run adds it or an earlier run did (its sources file is there), so
# a second run never drops coverage the first one set up.
UU_FILE=/etc/apt/apt.conf.d/52unattended-upgrades-f-snap
uu_sites=()
if ((NEED_MOZILLA)) || [[ -f /etc/apt/sources.list.d/mozilla.sources ]]; then
  uu_sites+=(packages.mozilla.org)
fi
if [[ -f /etc/apt/sources.list.d/element-io.sources ]] \
   || { snap_present element-desktop && grep -q '^element-desktop:apt:' "$APPLIST"; }; then
  uu_sites+=(packages.element.io)
fi
if ((${#uu_sites[@]})); then
  echo -e "\n🔄 Letting automatic updates cover these repositories: ${uu_sites[*]}"
  {
    echo "// Written by f-snap so unattended-upgrades updates the apps it installed from these"
    echo "// vendor repositories, as snapd did for the snaps. undo-f-snap.sh removes this file."
    echo "Unattended-Upgrade::Origins-Pattern {"
    printf '        "site=%s";\n' "${uu_sites[@]}"
    echo "};"
  } | write_root_file "$UU_FILE"
  log "uu_origins_file=$UU_FILE"
fi

run sudo apt-get update -qq

# Can apt's answers about an app's packages be trusted from here on? After a real run has
# written the sources above, yes. In a DRY run nothing was written, so unless a vendor's sources
# already existed, apt is still answering from the distro's own index - where the candidate for
# `firefox` is Ubuntu's epoch'd stub. Pre-flight must not read those answers as facts about the
# machine. Apps that come from Ubuntu's own archive need no added repo: their answer is final.
apt_answer_final() {
  ((DRY_RUN)) || return 0
  case "$1" in
    firefox|thunderbird) [[ -f /etc/apt/sources.list.d/mozilla.sources ]] ;;
    element-desktop)     [[ -f /etc/apt/sources.list.d/element-io.sources ]] ;;
    *)                   return 0 ;;
  esac
}

# Keep snapd for apps with no other source, but keep it small (current + 1 previous revision)
if command -v snap >/dev/null 2>&1; then
  run sudo snap set system refresh.retain=2
fi

# ${db:Status-Status} is "the package status word, part of the Status field (since dpkg
# 1.17.11)" - man dpkg-query. One word to compare, instead of matching the three-word
# ${Status} string.
pkg_installed() { [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]; }
pkg_version()   { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
apt_candidate() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}'; }

# Simulate an apt operation and return its output. Root, because man apt-get warns that
# "Simulations can also be executed by non-root users which might not have read access to all
# apt configuration distorting the simulation". A dry run holds no sudo credential by design,
# so it simulates unprivileged.
apt_simulate() {
  if ((DRY_RUN)); then
    apt-get -s "$@" 2>&1 || true
  else
    sudo apt-get -s "$@" 2>&1 || true
  fi
}

remove_snap_if_present() {
  local snapname="$1"
  # Capture, then match. `cmd | grep -q` under `set -o pipefail` can report failure even on a
  # match: grep exits at the first hit, the producer dies of SIGPIPE, and pipefail surfaces
  # that as a non-zero pipeline. It bites exactly when the producer has more to write.
  if grep -q "^$snapname\s" <<<"$(snap list 2>/dev/null || true)"; then
    echo "⚠️ Found Snap '$snapname' - attempting removal..."
    # No --purge: snapd keeps an automatic snapshot of the app's data (snap saved / snap restore)
    if ! run sudo snap remove "$snapname" </dev/null; then
      echo "❌ Could not fully remove $snapname"
    else
      log "snap_removed=$snapname"
    fi
  else
    echo "✔ Snap '$snapname' not installed."
  fi
}

# Some of Mozilla's channel packages ship the same files as the release one without declaring a
# conflict: firefox-esr (/usr/bin/firefox), and thunderbird-esr, -beta and -nightly (the
# Thunderbird icons). Installing the release package while one of them is there fails inside dpkg
# after apt has already said yes. apt's "pkg-" suffix removes it in the same transaction: one
# step, never a moment with neither installed. Firefox's beta, nightly and devedition share
# nothing. Prints the "<pkg>-" words to add to the install call.
esr_swaps() {
  local p c channels
  for p in "$@"; do
    case "$p" in
      firefox)     channels="firefox-esr" ;;
      thunderbird) channels="thunderbird-esr thunderbird-beta thunderbird-nightly" ;;
      *)           channels="" ;;
    esac
    for c in $channels; do
      if pkg_installed "$c"; then printf '%s-\n' "$c"; fi
    done
  done
  return 0
}

# The locales the system runs in, most specific first: the environment, then the system-wide
# setting the installer wrote and every login inherits (man 5 locale.conf; on 26.04
# /etc/default/locale is a symlink to it). LANGUAGE is a colon list. Values may be quoted.
system_locales() {
  local v f
  for v in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}" "${LANGUAGE:-}"; do
    [[ -n "$v" ]] && tr ':' '\n' <<<"$v"
  done
  for f in /etc/locale.conf /etc/default/locale; do
    [[ -r "$f" ]] || continue
    sed -n 's/^\(LC_ALL\|LC_MESSAGES\|LANG\|LANGUAGE\)=//p' "$f" | tr -d "\"'" | tr ':' '\n'
    break
  done
  return 0
}

# Mozilla's language pack for one locale, or nothing. $1 is the app, $2 a locale such as
# zh_CN.UTF-8. Mozilla names packs by its own codes (zh-cn, pt-br, es-es, nb-no): try the
# language and region, then the language alone, then the language's own region (es-es for
# es_UY, pt-pt for pt_AO), then the first region on offer, as Firefox falls back from es-UY to
# es-ES. English needs no pack unless the exact region has one: en-US is built in.
mozilla_langpack() {
  local app="$1" loc="$2" lang code c v
  loc="${loc%%.*}"; loc="${loc%%@*}"
  [[ -z "$loc" || "$loc" == C || "$loc" == POSIX ]] && return 0
  code="$(tr '[:upper:]_' '[:lower:]-' <<<"$loc")"
  # Hong Kong and Macau write Traditional Chinese, which Mozilla packs as zh-tw.
  [[ "$code" == zh-hk || "$code" == zh-mo ]] && code=zh-tw
  lang="${code%%-*}"
  for c in "$app-l10n-$code" "$app-l10n-$lang" "$app-l10n-$lang-$lang"; do
    v="$(apt_candidate "$c")"
    if [[ -n "$v" && "$v" != "(none)" ]]; then printf '%s\n' "$c"; return 0; fi
  done
  [[ "$lang" == en ]] && return 0
  apt-cache pkgnames "$app-l10n-$lang-" 2>/dev/null | sort | head -n 1
  return 0
}

# Ubuntu's firefox-locale-* and thunderbird-locale-* are empty transitional packages that depend
# on Ubuntu's stub, so replacing the stub removes them (Kylin, Unity and Ubuntu's Extended
# selection install them). Name each with apt's "pkg-" suffix so the removal is part of
# the planned transaction, and add Mozilla's language pack for each system locale: the snap
# bundles every language, Mozilla's deb ships en-US only. Prints the words to add to the install
# call; the packs depend on the exact app version, so they belong in the same call.
language_swaps() {
  local p stub ver loc pack seen=" "
  for p in "$@"; do
    [[ "$p" == firefox || "$p" == thunderbird ]] || continue
    # Only the transitional stubs (version 1snap1); a locale package with content would still
    # make the pre-flight refuse.
    while read -r stub ver; do
      [[ -n "$stub" && "$ver" == *snap* ]] && pkg_installed "$stub" && printf '%s-\n' "$stub"
    done < <(dpkg-query -W -f='${Package} ${Version}\n' "$p-locale-*" 2>/dev/null || true)
    while read -r loc; do
      pack="$(mozilla_langpack "$p" "$loc")"
      [[ -n "$pack" && "$seen" != *" $pack "* ]] || continue
      seen+="$pack "
      printf '%s\n' "$pack"
    done < <(system_locales)
  done
  return 0
}

# The target may name several packages, space-separated. They install in one apt-get call,
# which is the exact call pre-flight simulates. $2 is the app, which says whether a vendor repo is involved.
install_deb_app() {
  local pkgs pkg candidate installed todo=()
  read -ra pkgs <<<"$1"

  for pkg in "${pkgs[@]}"; do
    candidate="$(apt_candidate "$pkg")"
    installed="$(pkg_version "$pkg")"
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
      if ! apt_answer_final "$2"; then
        # Dry run, and the vendor repo that provides it has not been added: nothing to judge.
        echo "   [would install] $pkg, from the vendor repo the real run adds first"
        continue
      fi
      echo "❌ No installable candidate for '$pkg'. Is the repo configured and 'apt-get update' clean?"
      return 1
    fi
    if [[ "$installed" == "$candidate" ]]; then
      echo "✔ '$pkg' is already at the repo candidate ($candidate) - nothing to do."
      continue
    fi
    todo+=("$pkg")

    # THE 26.04 TRAP. Ubuntu's transitional package shares the package NAME with Mozilla's deb
    # (both are `firefox`) and carries an EPOCH: 1:1snap1-0ubuntu9.1. An epoch outranks every
    # upstream version, so apt orders Ubuntu's stub ABOVE Mozilla's 157.0.1~build1 and the swap
    # is a DOWNGRADE. Two independent gates then apply:
    #   1. Which version apt may pick - handled by the priority-1000 pin above
    #      (man 5 apt_preferences: "P >= 1000 causes a version to be installed even if this
    #      constitutes a downgrade of the package").
    #   2. Whether apt-get will PROCEED non-interactively - a separate refusal:
    #      "E: Packages were downgraded and -y was used without --allow-downgrades."
    # With only gate 1, `apt-get install -y firefox` exits non-zero and set -e kills the run.
    # --allow-downgrades closes gate 2, and apt replaces the stub in place - so this is ONE
    # command, and it is the exact command pre-flight simulates. Removing the stub first would
    # also work, but it would mean pre-flight testing a path the run does not take.
    if [[ -n "$installed" ]]; then
      echo "   $pkg installed: $installed    repo candidate: $candidate"
      if dpkg --compare-versions "$candidate" lt "$installed"; then
        echo "   ⚠️ the swap is a DOWNGRADE in apt's ordering (an epoch outranks any version)."
      fi
    fi
  done
  ((${#todo[@]})) || return 0

  local swaps=() langs=() s
  mapfile -t swaps < <(esr_swaps "${todo[@]}")
  mapfile -t langs < <(language_swaps "${todo[@]}")
  echo -e "\n🔧 Installing ${todo[*]} via APT..."
  for s in "${swaps[@]}"; do
    echo "   Replacing ${s%-}: it ships the same files, so the two cannot be installed together."
    ((DRY_RUN)) || log "esr_replaced=${s%-}"
  done
  for s in "${langs[@]}"; do
    if [[ "$s" == *- ]]; then
      echo "   Removing ${s%-}: an empty transitional package for Ubuntu's stub."
    else
      echo "   Adding $s: Mozilla's language pack for this system's locale."
    fi
  done
  run sudo apt-get install -y --allow-downgrades "${todo[@]}" "${swaps[@]}" "${langs[@]}" </dev/null
  ((DRY_RUN)) && return 0

  for pkg in "${todo[@]}"; do
    if ! pkg_installed "$pkg"; then
      echo "❌ '$pkg' still reports as not installed after apt-get succeeded."
      return 1
    fi
    echo "✅ '$pkg' installed: $(pkg_version "$pkg")"
  done
}

# Which scope can answer questions about the flathub remote? Normally the install scope, but
# during a dry run the remote-add was only printed, so the chosen scope may have no remote yet.
# An app ID is a property of the remote, so either installation answers it. Prints nothing and
# returns 1 if flathub is configured nowhere.
flathub_query_scope() {
  local s
  # Captured rather than piped into grep -q: see the SIGPIPE note in remove_snap_if_present.
  if grep -qx flathub <<<"$(flatpak remotes "$FLATPAK_SCOPE" --columns=name 2>/dev/null || true)"; then
    printf '%s' "$FLATPAK_SCOPE"
    return 0
  fi
  for s in --user --system; do
    if grep -qx flathub <<<"$(flatpak remotes "$s" --columns=name 2>/dev/null || true)"; then
      printf '%s' "$s"
      return 0
    fi
  done
  return 1
}

install_flatpak_app() {
  local id="$1" qscope other
  if flatpak info "$FLATPAK_SCOPE" "$id" >/dev/null 2>&1; then
    echo "✔ Flatpak '$id' is already installed ($FLATPAK_SCOPE) - nothing to do."
    return 0
  fi

  # Already in the OTHER installation? Say so before downloading a second copy. The two stores
  # are separate OSTree repositories, so a second copy costs the full size again (over a
  # gigabyte for two apps).
  other="--user"
  [[ "$FLATPAK_SCOPE" == "--user" ]] && other="--system"
  if flatpak info "$other" "$id" >/dev/null 2>&1; then
    echo "⚠️ '$id' is already installed in the $other store."
    echo "   Installing it $FLATPAK_SCOPE as well means TWO copies - the stores are separate"
    echo "   repositories and share nothing. Remove the other one with:"
    if [[ "$other" == "--system" ]]; then
      echo "       sudo flatpak uninstall --system -y $id"
    else
      echo "       flatpak uninstall --user -y $id"
    fi
  fi
  echo -e "\n🔧 Installing '$id' via Flatpak ($FLATPAK_SCOPE)..."

  if qscope="$(flathub_query_scope)"; then
    if flatpak remote-info "$qscope" flathub "$id" >/dev/null 2>&1; then
      echo "   ✔ '$id' resolves on Flathub"
    else
      echo "❌ '$id' does not resolve on the flathub remote (checked in the $qscope scope)."
      echo "   Check the app ID in apps.conf."
      return 1
    fi
  else
    echo "   ℹ️ flathub is not configured in any scope yet, so '$id' cannot be checked here."
  fi
  flatpak_scoped install -y flathub "$id" </dev/null
  ((DRY_RUN)) && return 0
  if ! flatpak info "$FLATPAK_SCOPE" "$id" >/dev/null 2>&1; then
    echo "❌ Flatpak '$id' not present after install."
    return 1
  fi
  echo "✅ Flatpak '$id' installed."
}

# PHASE 1 of 2 - prove every replacement will install, BEFORE a single Snap is removed.
#
# Removing the Snap first is the right order: a Snap left installed is one the user may open,
# and opening it creates a fresh empty profile under ~/snap that then has to be cleaned up. But
# remove-first is only safe if the install is known to work - and apt will say so in advance if
# asked. The epoch downgrade refusal appears in `apt-get -s` output without touching anything:
#   E: Packages were downgraded and -y was used without --allow-downgrades.
# So: ask every question first, change nothing until every answer is good.
preflight_all() {
  local app method config_path target problems=() candidate sim removals qscope p
  echo -e "\n🔎 Pre-flight: proving every replacement installs, before anything is removed"

  while IFS=: read -r app method config_path target <&3; do
    [[ "$app" =~ ^#.*$ || -z "$app" ]] && continue

    # A broken catalog entry is a problem whether or not its Snap is here today.
    if [[ "$method" != "apt" && "$method" != "flatpak" ]]; then
      problems+=("$app: unknown method '$method' in apps.conf (expected 'apt' or 'flatpak')")
      continue
    fi
    if ! snap_present "$app"; then
      echo "   - $app: no Snap installed, nothing to replace"
      continue
    fi

    if [[ "$method" == "apt" ]]; then
      local pkgs pkg todo=() bad=0 pending=0
      read -ra pkgs <<<"$target"
      for pkg in "${pkgs[@]}"; do
        candidate="$(apt_candidate "$pkg")"
        # A rehearsal on a machine that has never had the vendor repo added cannot know the
        # answer: report that honestly instead of failing the rehearsal or, worse, reporting
        # a stub as "already at the candidate" and planning to skip the package.
        if ! apt_answer_final "$app"; then
          if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
            echo "   ⚠️ $app: cannot check '$pkg' yet - the real run adds the vendor repo first"
          else
            echo "   ⚠️ $app: '$pkg' shows $candidate from the CURRENT sources only -"
            echo "        the real run adds the vendor repo first, which can change this answer"
          fi
          pending=1
          continue
        fi
        if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
          problems+=("$app: no APT candidate for '$pkg' - is the repo configured and 'apt-get update' clean?")
          bad=1
          continue
        fi
        [[ "$(pkg_version "$pkg")" == "$candidate" ]] || todo+=("$pkg")
      done
      ((bad || pending)) && continue
      if ((${#todo[@]} == 0)); then
        echo "   ✔ $app: '$target' already at the candidate"
        continue
      fi
      # Exactly the command phase 2 runs, so a pass here means a pass there.
      local swaps=() langs=()
      mapfile -t swaps < <(esr_swaps "${todo[@]}")
      mapfile -t langs < <(language_swaps "${todo[@]}")
      sim="$(apt_simulate install -y --allow-downgrades "${todo[@]}" "${swaps[@]}" "${langs[@]}")"
      if grep -q '^E:' <<<"$sim"; then
        problems+=("$app: apt will not install '${todo[*]}' - $(printf '%s\n' "$sim" | grep -m1 '^E:')")
        continue
      fi
      removals="$(printf '%s\n' "$sim" | awk '/^Remv /{print $2}' \
        | grep -vxF -f <(printf '%s\n' "${todo[@]}" "${swaps[@]%-}" "${langs[@]%-}") || true)"
      if [[ -n "$removals" ]]; then
        problems+=("$app: installing '${todo[*]}' would also REMOVE $(printf '%s' "$removals" | tr '\n' ' ')")
        continue
      fi
      echo "   ✔ $app: '${todo[*]}' installs cleanly (apt simulated it)"
      if ((${#swaps[@]})); then
        echo "     It replaces ${swaps[*]%-}, which ships the same files."
      fi
      for p in "${langs[@]}"; do
        if [[ "$p" == *- ]]; then
          echo "     It removes ${p%-}, an empty transitional package for Ubuntu's stub."
        else
          echo "     It adds $p, Mozilla's language pack for this system's locale."
        fi
      done

    else
      if flatpak info "$FLATPAK_SCOPE" "$target" >/dev/null 2>&1; then
        echo "   ✔ $app: '$target' already installed ($FLATPAK_SCOPE)"
        continue
      fi
      if qscope="$(flathub_query_scope)"; then
        if flatpak remote-info "$qscope" flathub "$target" >/dev/null 2>&1; then
          echo "   ✔ $app: '$target' resolves on Flathub"
        else
          problems+=("$app: '$target' does not resolve on Flathub - check the app ID in apps.conf")
        fi
      else
        echo "   ⚠️ $app: flathub is not configured yet, so '$target' cannot be checked here"
      fi

    fi
  done 3< "$APPLIST"

  if ((${#problems[@]})); then
    echo ""
    echo "❌ Pre-flight failed, so no Snap has been removed. Every Snap is still installed."
    for p in "${problems[@]}"; do
      echo "   - $p"
    done
    log "preflight_failed count=${#problems[@]}"
    return 1
  fi
  echo "   All replacements check out."
}

# Pre-flight cleared this app, so getting here means something changed underneath us mid-run
# (network, repo, Flathub). The Snap is already gone, so say exactly how to get it back.
install_failed_after_removal() {
  local app="$1" target="$2"
  echo ""
  echo "❌ '$target' failed to install, and the '$app' Snap has already been removed."
  echo "   Pre-flight passed for it, so something changed mid-run - check the network and"
  echo "   the repository, then run f-snap again."
  echo "   To put the Snap back in the meantime:"
  echo "       sudo snap install $app"
  log "install_failed_after_snap_removal app=$app target=$target"
  FAILED_APPS+=("$app")
}

# Copy a Snap profile only when there is NO existing profile. Never move or replace an
# existing one: on a fresh install with /home kept, the real profile is already in place and
# a Snap profile is likely a new, empty one.
#
# $2 is apps.conf's config field: one or more folders relative to $HOME, separated by "|".
# Mozilla's apps keep the legacy folder (~/.mozilla, ~/.thunderbird) if it exists and otherwise
# use the XDG one under ~/.config, so either one counts as an existing profile.
#
# Where a snap keeps it varies by app: Firefox under $SNAP_USER_COMMON (~/snap/firefox/common),
# Thunderbird and Element under the revision folder's .config (their XDG_CONFIG_HOME). "current"
# is a symlink snapd does not always create, so the newest revision folder is searched too.
# Checked with `snap run --shell <app>` on 26.04 (docs/research/apps.md).
snap_config_source() {
  local app="$1" alt root rev
  rev="$(find "$HOME/snap/$app" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' 2>/dev/null \
         | sort -V | tail -1 || true)"
  for root in "$HOME/snap/$app/common" "$HOME/snap/$app/current" ${rev:+"$rev"}; do
    for alt in ${2//|/ }; do
      if [[ -d "$root/$alt" ]]; then printf '%s\t%s\n' "$root/$alt" "$alt"; return 0; fi
    done
  done
  return 0
}

migrate_config_if_needed() {
  local app="$1" alts="$2" alt found src rel target_path
  [[ "$alts" == "-" || -z "$alts" ]] && return 0   # apps.conf "-": no profile
  found="$(snap_config_source "$app" "$alts")"
  for alt in ${alts//|/ }; do
    if [[ -d "$HOME/$alt" ]]; then
      echo "✔ Existing config for $app at $HOME/$alt - leaving it as is."
      if [[ -n "$found" ]]; then
        echo "ℹ️ A Snap config also exists at ${found%%$'\t'*} (not copied)."
        log "config_left_in_snap=${found%%$'\t'*}"
      fi
      return 0
    fi
  done
  if [[ -z "$found" ]]; then
    echo "ℹ️ No config found for $app"
    return 0
  fi
  src="${found%%$'\t'*}"; rel="${found#*$'\t'}"; target_path="$HOME/$rel"
  echo "📦 No config at $target_path - copying it from $src"
  run mkdir -p "$(dirname "$target_path")"
  run cp -a "$src" "$target_path"
  log "config_copied=$src -> $target_path"
  repoint_mozilla_profiles "$app" "$target_path"
}

# Firefox and Thunderbird give each install its own profile. A new install adopts the existing
# default profile only if its compatibility.ini says this same install last used it; a copied
# snap profile names /snap/<app>/<rev>/..., so the deb would start a new, empty profile instead
# (support.mozilla.org, "Understanding in depth the profile per installation feature"). Pointing
# those lines at the deb's install folder makes the deb adopt the copied profile, as proven in a
# VM: it became the install's default and kept the snap profile's settings.
repoint_mozilla_profiles() {
  local app="$1" dir="$2" platform appdir f
  case "$app" in
    firefox)     platform=/usr/lib/firefox;     appdir=/usr/lib/firefox/browser ;;
    thunderbird) platform=/usr/lib/thunderbird; appdir=/usr/lib/thunderbird ;;
    *) return 0 ;;
  esac
  if ((DRY_RUN)); then
    echo "   [would point] each copied profile's compatibility.ini at $platform, so the deb adopts it"
    return 0
  fi
  while IFS= read -r f; do
    if ! grep -q '^LastPlatformDir=/snap/' "$f"; then continue; fi
    sed -i -e "s#^LastPlatformDir=.*#LastPlatformDir=$platform#" -e "s#^LastAppDir=.*#LastAppDir=$appdir#" "$f"
    echo "   Pointed $(basename "$(dirname "$f")") at $platform, so the deb $app opens it."
  done < <(find "$dir" -mindepth 2 -maxdepth 3 -name compatibility.ini 2>/dev/null)
}

preflight_all
PROCESSED_SNAPS=()

# PHASE 2 of 2 - PROCESS EACH APP.
#
# The Snap goes first, now that pre-flight has proved the replacement installs. Leaving a Snap
# in place while its replacement is installed sounds safer but is not: a Snap that is still
# there is one the user can open, and opening it creates a fresh empty profile under ~/snap
# that then has to be spotted and cleaned up. If an install fails anyway, the user is told
# exactly how to put the Snap back, rather than being left to guess.
#
# The config file is read on FD 3, not stdin: sudo, apt-get, snap and flatpak all inherit
# stdin from the loop, and on stdin they would eat the remaining lines of apps.conf and
# silently skip apps. Inner commands also get </dev/null for the same reason.
while IFS=: read -r app method config_path target <&3; do
  [[ "$app" =~ ^#.*$ || -z "$app" ]] && continue
  snap_present "$app" || continue
  PROCESSED_SNAPS+=("$app")
  echo -e "\n🔧 Processing: $app ($method)"
  log "[$app]"

  migrate_config_if_needed "$app" "$config_path"
  remove_snap_if_present "$app"

  if [[ "$method" == "apt" ]]; then
    install_deb_app "$target" "$app" || install_failed_after_removal "$app" "$target"
  else
    install_flatpak_app "$target" || install_failed_after_removal "$app" "$target"
  fi
  log "action=$method"
  log "target=$target"
done 3< "$APPLIST"

# Support snaps left behind. Removing an app Snap leaves its base and the content snaps it
# used (GNOME platform, Mesa, themes, codecs), and nothing removes them on its own. What is
# still needed is computed, not guessed: every remaining snap that is not itself a support snap
# keeps its base (no base means `core`) and each content snap its meta/snap.yaml names as a
# default-provider, recursively. A support snap is a base (type base/os) or a snap with a
# content slot; mesa-2404 ships an app, so "has apps" cannot tell them apart. Anything
# unneeded goes: content snaps first, then the bases they ran on. snapd always stays.
snap_meta() { cat "/snap/$1/current/meta/snap.yaml" 2>/dev/null || true; }
snap_is_support() {
  local meta type
  meta="$(snap_meta "$1")"
  type="$(awk '/^type:/{print $2; exit}' <<<"$meta")"
  [[ "$type" == "base" || "$type" == "os" ]] && return 0
  awk '/^slots:/{s=1; next} /^[a-z]/{s=0} s && /interface: *content/{found=1} END{exit !found}' <<<"$meta"
}
snap_needs() {
  local meta type base
  meta="$(snap_meta "$1")"
  type="$(awk '/^type:/{print $2; exit}' <<<"$meta")"
  base="$(awk '/^base:/{print $2; exit}' <<<"$meta")"
  if [[ -n "$base" ]]; then
    echo "$base"
  elif [[ -z "$type" || "$type" == "app" ]]; then
    echo core
  fi
  awk '/default-provider:/{sub(/:.*/, "", $2); print $2}' <<<"$meta"
}

remove_orphaned_support_snaps() {
  local s remaining=() roots=() support=() queue=() orphans=() bases=() content=() conns gone
  local -A needed=()
  echo -e "\n🧹 Support snaps nothing needs any more"
  if [[ "$KEEP_SUPPORT_SNAPS" == 1 ]]; then
    echo "   Leaving them (--keep-support-snaps)."
    return 0
  fi

  # A dry run removed nothing, so leave out the apps it would have removed.
  for s in $(snap list 2>/dev/null | awk 'NR>1{print $1}' || true); do
    [[ " ${PROCESSED_SNAPS[*]} " == *" $s "* ]] && ((DRY_RUN)) && continue
    remaining+=("$s")
  done
  for s in "${remaining[@]}"; do
    [[ "$s" == "snapd" ]] && continue
    if snap_is_support "$s"; then support+=("$s"); else roots+=("$s"); fi
  done

  queue=("${roots[@]}")
  while ((${#queue[@]})); do
    s="${queue[0]}"; queue=("${queue[@]:1}")
    while read -r dep; do
      [[ -z "$dep" || -n "${needed[$dep]:-}" ]] && continue
      needed[$dep]=1
      queue+=("$dep")
    done < <(snap_needs "$s")
  done

  for s in "${support[@]}"; do
    [[ -n "${needed[$s]:-}" ]] && continue
    orphans+=("$s")
  done
  if ((${#orphans[@]} == 0)); then
    echo "   None: every installed support snap is still used."
    return 0
  fi

  for s in "${orphans[@]}"; do
    case "$(awk '/^type:/{print $2; exit}' <<<"$(snap_meta "$s")")" in
      base|os) bases+=("$s") ;;
      *)       content+=("$s") ;;
    esac
  done
  if ((${#needed[@]})); then
    echo "   Still used by an installed app: ${!needed[*]}"
  fi
  for s in "${content[@]}" "${bases[@]}"; do
    # Double-check snapd's own view: a connected content slot means something this analysis
    # missed still uses it. Theme snaps are the usual case: snapd connects them to every snap
    # app's gtk-3-themes plug without either side naming the other as a default-provider.
    # Columns: Interface Plug Slot Notes. Only rows where THIS snap provides the slot and
    # another snap's plug is attached mean something uses it; its own unconnected plugs show up
    # too, with "-" in the slot column. A dry run removed nothing, so it ignores connections
    # from the apps this run would remove - otherwise it would plan differently from the run.
    gone=" "
    if ((DRY_RUN)); then gone=" ${PROCESSED_SNAPS[*]} "; fi
    conns="$(snap connections "$s" 2>/dev/null \
      | awk -v s="$s" -v gone="$gone" \
          'NR>1 && index($3, s":") == 1 && $2 != "-" {
             split($2, p, ":"); if (index(gone, " " p[1] " ") == 0) print }' || true)"
    if [[ -n "$conns" ]]; then
      echo "   Keeping $s: snapd reports it connected to $(awk '{split($2, p, ":"); print p[1]}' <<<"$conns" | sort -u | tr '\n' ' ')"
      continue
    fi
    # No --purge: snapd keeps its automatic snapshot, as for the apps.
    if run sudo snap remove "$s" </dev/null; then
      ((DRY_RUN)) || log "support_snap_removed=$s"
    else
      echo "   ⚠️ snapd would not remove $s; leaving it."
    fi
  done
}

if command -v snap >/dev/null 2>&1; then
  remove_orphaned_support_snaps
fi

# A Flatpak store not moved yet (no Flatpak apps this run) moves now that every package is in.
relocate_flatpak_if_wanted

# After the apps: their removals free nothing on the root partition (the seed stays), but they
# leave fewer snaps mounted while snapd is stopped for the copy.
if command -v snap >/dev/null 2>&1; then
  relocate_snapd_if_wanted
fi

# update-desktop-database builds the MIME-type cache ("a cache database of the MIME types
# handled by desktop files" - man update-desktop-database), NOT the menu; kbuildsycoca6 is
# what rebuilds KDE's menu cache. Both are wanted after apps appear or disappear.
# Both are desktop niceties, absent on a server or in a container - their absence must not
# fail a run that has otherwise done its job.
if command -v kbuildsycoca6 >/dev/null 2>&1 || command -v kbuildsycoca5 >/dev/null 2>&1; then
  echo -e "\n🧹 Refreshing the MIME cache and KDE menu cache..."
else
  echo -e "\n🧹 Refreshing the MIME cache..."
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  run sudo update-desktop-database
else
  echo "   update-desktop-database not installed - skipping the MIME cache."
fi
if ! ((DRY_RUN)); then
  kbuildsycoca6 --noincremental 2>/dev/null || kbuildsycoca5 --noincremental 2>/dev/null || true
fi

if ((DRY_RUN)); then
  echo -e "\n🧪 DRY RUN finished. Nothing was changed."
  echo -e "   If the plan above is what you want, run it for real: ./f-snap.sh"
elif ((${#FAILED_APPS[@]})); then
  log "RUN COMPLETE WITH FAILURES: ${FAILED_APPS[*]}"
  echo -e "\n⚠️ Finished, but these apps have no replacement installed: ${FAILED_APPS[*]}"
  echo -e "   Their Snaps were removed. Scroll up for the exact recovery command for each."
  echo -e "   Log: $LOGFILE"
  exit 1
else
  log "RUN COMPLETE"
  echo -e "\n✅ Snap replacement complete. Log: $LOGFILE"
  echo -e "\n🔎 Run './verify-f-snap.sh' to check results."
fi

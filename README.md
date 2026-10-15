# f-snap!

*The f stands for "Forget." That's the radio edit.*

**Get your Ubuntu apps back from snap.** Ubuntu 26.04 and its flavors install Firefox, Thunderbird and more as snaps. f-snap swaps them for the packages their own makers publish, brings your bookmarks and mail along, and can move gigabytes of snap and Flatpak data off your root partition. Rehearse it with a dry run first, and undo it if you change your mind.

## Quick start

```bash
git clone https://github.com/markrusselldev/f-snap.git
cd f-snap
./f-snap.sh --dry-run   # shows exactly what it would do, changes nothing
./f-snap.sh             # does it
```

## What you get

- **Swaps app snaps where the replacement is better** - Firefox and Thunderbird from Mozilla's APT repository, Element from Element's, Krita from Flathub. The table below says why for each.
- **Carries your profile over.** If you used the snap version of Firefox, Thunderbird or Element, its profile is copied to where the new app looks and set as that app's default, so you open your own bookmarks and mail. A profile you already had outside the snap is never overwritten. (Krita's Flathub build keeps its data elsewhere, so the snap's Krita settings stay in the snapshot `snap remove` keeps.)
- **Keeps the new apps updating.** Snaps update themselves; f-snap adds the vendor repositories to Ubuntu's automatic updates so the replacements do too.
- **Cleans up after itself.** Support snaps (GNOME platform, Mesa, themes, codecs) that no remaining snap uses are removed. `snapd` always stays.
- **Can move snap and Flatpak data off the root partition**, if you want. Most of snap's space is the installer's copy of every snap it shipped, which snapd keeps for good: 3.9 GB on a fresh Kubuntu 26.04.1, 1.6 GB on Ubuntu *(system verified 2026-10-14)*. f-snap can move all of it to `/home`.
- **Leaves alone** Ubuntu's own snap-only tools (App Center, Firmware Updater, Security Center and the rest), your existing profiles, and every package and setting it has no reason to touch.

## What each app becomes, and why *(upstream verified 2026-10-14)*

f-snap swaps an app only when the replacement is better for you, never just because another package exists. The sources behind each choice are in [docs/research/apps.md](docs/research/apps.md).

| Snap | Becomes | Why |
|---|---|---|
| Firefox | Mozilla's APT repository | Mozilla labels its APT repository "recommended" for Ubuntu. On 26.04 the snap has broken Kerberos sign-on and no AV1 hardware video decoding on some Intel graphics. |
| Thunderbird | Mozilla's APT repository | Mozilla labels it "recommended". The snap cannot reach a profile outside your home folder. |
| Element | Element's own APT repository | It is the build Element publishes and the newest; the snap comes from an individual and lags behind. |
| Krita | Flathub | Flathub has the current Krita 5.3 from the Krita Foundation. The snap is stuck at 5.2.11 from July 2025, and Ubuntu's own package is the Qt6 build Krita calls early access. |
| FreeShow (Ubuntu Studio) | stays a snap | The snap is current. Upstream offers only a one-off `.deb` that never updates, and FreeShow is not on Flathub. |
| App Center, Firmware Updater, Security Center, prompting-client, snapd-desktop-integration, hwctl, Budgie Welcome | stay snaps | These are Ubuntu's own system tools. Ubuntu ships them as snaps and builds on them; on 26.04 App Center is its one place to manage apps, debs included. Swapping them would make the system more fragile, not better. |
| Theme snaps (Breeze, Orchis) | removed once unused | They only theme other snaps, so f-snap removes them when no snap app is left to use them. |

## Tested on *(system verified 2026-10-14)*

Each of these was installed fresh in a virtual machine, with `/home` on its own disk, and taken through the dry run, the real run with both stores moved, `verify-f-snap.sh`, a reboot, and `undo-f-snap.sh`:

| 26.04.1 | Snaps replaced |
|---|---|
| Ubuntu | Firefox |
| Kubuntu, with Krita and Element ticked in the installer | Firefox, Thunderbird, Element, Krita |
| Ubuntu Studio | Firefox, Thunderbird |
| Xubuntu | Firefox, Thunderbird |

The other flavors (Edubuntu, Lubuntu, Ubuntu MATE, Budgie, Cinnamon, Kylin, Unity) install a subset of these snaps but have not been tested themselves. Older Ubuntu releases have not been tested.

On a system that is not Ubuntu or a flavor (Debian, Linux Mint, Pop!_OS), f-snap only offers to move the snap and Flatpak stores. Its app swaps are built for Ubuntu's packages.

## Rehearse first

Four ways to see what f-snap will do before it does it:

1. **Dry run.** `./f-snap.sh --dry-run` changes nothing and needs no sudo. It prints every command the real run would run, every file it would write with its exact contents, and apt's own simulation of each install, including any package apt would remove.
2. **Pre-flight.** The real run proves every replacement installs, by simulating it with the new repositories in place, before it removes a single snap. If one would fail, it stops with every snap still installed.
3. **A test VM**, if you want certainty for your flavor: snapshot a fresh install of it in a virtual machine, run f-snap there, and check the result with `verify-f-snap.sh`.
4. **A log.** Every change is written to `f-snap.log` next to the script, and a failure prints and logs the exact line and command that failed. `undo-f-snap.sh` works from that log.

## Usage

Start with the dry run (see [Quick start](#quick-start)). Then close the snap apps you are replacing, and run it for real:

```bash
./f-snap.sh
```

It asks for your password once, at the start, and asks the big questions (replace apps, move stores) before it changes anything. Every question also has an option below that answers it, so a run can be unattended.

After a reboot, check the result:

```bash
./verify-f-snap.sh
```

`verify-f-snap.sh` checks that each replaced snap is gone and its replacement installed, that moved stores are still mounted, that no snap failed to mount, and that the automatic updates cover the new repositories. It exits non-zero if anything is wrong.

### Options

| Option | Effect |
|---|---|
| `--dry-run`, `-n` | Change nothing; print the plan. |
| `--stores-only` | Only offer to move the snap and Flatpak stores; replace no apps. |
| `--replace-apps` | Replace the app snaps without asking. |
| `--snapd-dir=PATH`, `--keep-snapd-dir` | Move snapd's data to PATH, or leave it. Skips that question. |
| `--flatpak-dir=PATH`, `--keep-flatpak-dir` | Move the system Flatpak store to PATH, or leave it. Skips that question. |
| `--install-scope=system\|user` | Which Flatpak store new apps go into. Skips that question. |
| `--keep-support-snaps` | Keep support snaps even when nothing uses them. |
| `--disable-mozillateam-ppa`, `--keep-mozillateam-ppa` | Answer the offer to disable an old Mozilla PPA. |

`./f-snap.sh --help` lists them all.

## Undo

```bash
./undo-f-snap.sh --dry-run
./undo-f-snap.sh
```

Undo reads `f-snap.log` and removes the apps f-snap installed, the Flatpak runtimes only they used, and f-snap's automatic-updates file, and re-enables an old Mozilla PPA it disabled. It does not reinstall the snaps; it prints the `snap install` commands for that. It leaves moved stores where they are, since the apps work the same from either place, and prints how to remove the Mozilla and Element repositories if you want them gone. Profiles are never touched: the copies f-snap made stay, and `snap remove` kept its own snapshot of each snap's data (`snap saved` lists them).

## Add your own apps

The swaps live in `apps.conf`, and you can add your own. f-snap acts only on lines whose snap is installed, so one file serves every machine. Say you installed VLC as a snap and want Ubuntu's own package instead; add one line:

```
vlc:apt:-:vlc
```

or, for the Flathub build:

```
vlc:flatpak:-:org.videolan.VLC
```

Run `./f-snap.sh --dry-run` to see what it will do with it. Each line is `snap:method:profile:target`:

- **snap**: the snap's name, as `snap list` shows it.
- **method**: `apt` or `flatpak`.
- **profile**: the folder under your home where the app keeps its settings, if you want them carried over from the snap; several separated by `|` when the app uses whichever exists; `-` for none.
- **target**: the APT package (several, space-separated, install together) or the Flathub app ID.

The lines that ship with f-snap are backed by the research in [docs/research/apps.md](docs/research/apps.md). The ones you add are your call.

## How it works

### Moving stores off the root partition

snapd and Flatpak have no setting for where they keep their data, so f-snap moves the whole folder (`/var/lib/snapd`, `/var/lib/flatpak`) to the path you choose (default `/home/snapd`, `/home/flatpak`) and bind-mounts it back through `/etc/fstab`. Every program keeps using the original path. The original is kept as `*.pre-relocate` until you delete it; for snapd, reboot first, because running snaps use the old copy until then. f-snap refuses a target on the same filesystem, since that frees nothing.

Your per-user Flatpak store, `~/.local/share/flatpak`, is already on the home filesystem, so f-snap does not move it. Exclude it from your backups instead; everything in it can be downloaded again.

Docker has its own supported setting for this (`data-root` in `/etc/docker/daemon.json`, plus containerd's `root`), so f-snap leaves Docker alone.

### Profiles

Firefox and Thunderbird give each installation its own profile, and a new installation only adopts an existing profile if that profile says the same installation last used it. A profile copied from a snap names the snap, so on its own the new app would quietly start an empty profile. f-snap points the copied profile at the new installation, so the new app opens it with your settings.

### Mozilla's repository

f-snap adds Mozilla's repository only when it is replacing Firefox or Thunderbird. It checks the signing key against the fingerprint Mozilla publishes before trusting it, writes one sources file with both the Firefox and Thunderbird suites, and pins Mozilla's packages above Ubuntu's. Ubuntu's own `firefox` and `thunderbird` packages only install the snap, and their version numbers outrank Mozilla's (an epoch), so they are blocked and the swap is made with `--allow-downgrades`. Mozilla's ESR packages, and Thunderbird's beta and nightly ones, share files with the regular packages, so if one is installed f-snap swaps it out in the same step instead of failing halfway.

## Help

Open an issue on [GitHub](https://github.com/markrusselldev/f-snap/issues) with your flavor, release, and the end of `f-snap.log`.

## License

Copyright (C) 2025-2026 Mark David Russell. f-snap is free software under the GNU General Public License, version 3 or later: you may use, share and change it, and anything you distribute that is built on it must be shared under the same terms. It comes with no warranty. See [LICENSE](LICENSE).

# Which source is better for users, app by app

*The evidence behind the app choices in the [README](../../README.md).*

The test for every swap: is the replacement better for the person using the app? A package
existing is not a reason. Ubuntu's own system tools stay snaps.

## Firefox: which source is better for users

### Verdict: Mozilla's APT repository *(upstream verified 2026-10-14)*

| Finding | Source |
|---|---|
| Mozilla labels its DEB repository "(recommended)" for Debian and Ubuntu; Flatpak and Snap are listed as other options | support.mozilla.org/kb/install-firefox-linux, updated 2026-08-16 |
| On 26.04 the snap's `kerberos-tickets` plug stopped passing SSO tickets (worked on 24.04) | forum.snapcraft.io/t/51417 (2026-05-14), Launchpad bug 2152233 |
| On 26.04 the snap decodes AV1 in software on Intel where the Flatpak and Mozilla's tarball use the GPU | discourse.ubuntu.com/t/82492 (2026-05-18), Launchpad bug 2153181 |
| A user's snap-only protocol-handler bug did not reproduce in Mozilla's deb | discourse.ubuntu.com/t/70840 (2025-10-24) |

## Thunderbird: which source is better for users

### Verdict: Mozilla's APT repository *(upstream verified 2026-10-14)*

| Finding | Source |
|---|---|
| Mozilla labels its DEB repository "(recommended)"; the Flatpak is "maintained directly by the Thunderbird staff"; the snap is "maintained by Canonical and Thunderbird" | support.mozilla.org/kb/installing-thunderbird-linux, updated 2026-08-20 |
| The snap could not sign mail through external GnuPG (smart cards, YubiKeys) for three years; fixed in the stable channel 2026-03-09, with related key errors split to bug 2137539 | Launchpad bug 2009825 |
| Snap confinement cannot reach a profile outside the home folder (an encrypted volume, a second disk) | support.mozilla.org/questions/1469510 and /1484204 (24.04 reports) |

The snap follows the release channel, so the deb is `thunderbird`, not `thunderbird-esr`.

## Element: which source is better for users

### Verdict: Element's own APT repository *(upstream verified 2026-10-14)*

| Finding | Source |
|---|---|
| Element gives APT instructions for Debian and Ubuntu from its own repository, `https://packages.element.io/debian/ default main`, package `element-desktop`; it lists Flatpak under "Community maintained packages" and does not mention a snap | element.io/download |
| Element's repository carries 1.12.31 (index updated 2026-10-14) | packages.element.io/debian Packages index |
| The snap is published by an individual, not Element, and is at 1.12.29 (2026-09-25) | snapcraft.io/element-desktop |
| The Flathub build is at 1.12.29 (2026-09-22) and not verified | flathub.org/api/v2/appstream/im.riot.Riot |
| Element publishes no key fingerprint, so f-snap fetches the key over HTTPS as Element instructs: uid "riot.im packages", fingerprint 12D4CD600C2240A9F4A82071D7B0B66941D01538 | packages.element.io, fetched 2026-10-13 |

## Krita: which source is better for users

### Verdict: Flathub, not APT *(upstream verified 2026-10-14)*

| Finding | Source |
|---|---|
| The snap is stuck at 5.2.11, last updated 2025-07-08; Krita lists both the snap and the Flatpak as "Maintained by the community" | snapcraft.io/krita; krita.org/en/download (5.3.4.1, 2026-10-07) |
| Flathub ships 5.3.4.1 (2026-10-07), verified as published by the Krita Foundation | flathub.org/api/v2/appstream/org.kde.krita |
| Ubuntu's archive has 6.0.1 (2026-03-31), the Qt6 build, compiled with `-DALLOW_UNSTABLE=QT6` | `apt-get changelog krita` on 26.04 |
| Krita calls 6.0 "early access" and warns "there will be bugs in Krita 6 that are not present in Krita 5"; both share the same features apart from Wayland | krita.org/en/release-notes/krita-5-3-release-notes (2026-02-05) |

## FreeShow (Ubuntu Studio): which source is better for users

### Verdict: keep the snap *(upstream verified 2026-10-14)*

| Finding | Source |
|---|---|
| The snap is current: 1.6.6, updated 2026-10-09, the day upstream released it; its publisher also packages Ubuntu Studio | snapcraft.io/freeshow; Ubuntu changelogs |
| Upstream ships a one-off `.deb`, `.rpm` and AppImage per GitHub release (v1.6.6, 2026-10-09); there is no APT repository, so a `.deb` never updates | api.github.com/repos/ChurchApps/FreeShow/releases/latest |
| FreeShow is not on Flathub | flathub.org/api/v2/search for "freeshow" |

## Ubuntu's own system tools, which stay snaps

### Canonical's and the flavors' own tools stay snaps *(upstream verified 2026-10-14)*

f-snap does not swap these. They are part of the operating system, and Ubuntu ships them only as
snaps or is moving them there.

| Snap | What it is | Source |
|---|---|---|
| snap-store (App Center) | Ubuntu's app manager | see below |
| firmware-updater | Ubuntu's firmware update tool | Snap Store description |
| desktop-security-center | Ubuntu Pro, snap app permissions, disk-encryption recovery keys | Snap Store description (Canonical) |
| prompting-client | the permission prompts for snaps, used with the Security Center | Snap Store description |
| snapd-desktop-integration | session bridge to snapd | Snap Store description |
| hwctl | Canonical is making it snap-only for GNOME Control Center | Launchpad bug 2156756, "Migrate to snap-only", 2026-06-15 |
| ubuntu-budgie-welcome | Ubuntu Budgie's welcome tool; the archive `budgie-welcome` 0.6.2 is far behind the snap 0.27.2 | apt-cache show; Snap Store (2026-10-13) |

### App Center *(upstream verified 2026-10-14)*

| Finding | Source | Consequence |
|---|---|---|
| Canonical's plan for 26.04 makes App Center "the single place to handle all applications, independently of the packaging format", including "fully managing deb packages", and starts deprecating Software Properties | discourse.ubuntu.com/t/72740, "Ubuntu 26.04 LTS - The Roadmap" (jibel, 2025-11-26) | Ubuntu's future system features land in App Center |
| 26.04 shipped App Center with third-party deb installation and no longer includes Software & Updates by default; 26.04.1 shows debs and snaps side by side | documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users; ubuntu.com/blog/upgrade-your-desktop-ubuntu-26-04-lts | The "App Center ignores debs" complaint behind the 24.04 swap guides no longer holds |
| Users who install GNOME Software on Ubuntu do it for Flatpak, which App Center does not offer, and install it alongside App Center rather than in place of it | itsfoss.com/ubuntu-gnome-software-center (2024-08-02); 26.04 roadmap thread replies | Wanting Flatpak is a reason to add GNOME Software, not to remove App Center |

## Theme snaps (Kubuntu, Ubuntu Studio)

### They are support snaps, not apps *(system verified 2026-10-15)*

| Finding | Source |
|---|---|
| `gtk-theme-breeze` and `icon-theme-breeze` (publisher KDE) and `gtk-theme-orchis` (publisher Erich Eickmeyer) are `base: bare` snaps with a content slot: they only theme other snaps | api.snapcraft.io/v2/snaps/info, `snap-yaml` |

So they are not swapped. f-snap's support-snap pass treats them like any content snap: it keeps
one while snapd reports it connected to a remaining app, and removes it once no app snap uses it.

| Finding | Source |
|---|---|
| On Ubuntu Studio 26.04.1 snapd connects `gtk-theme-orchis` to the `gtk-3-themes` plug of desktop-security-center, firmware-updater, freeshow, prompting-client and snapd-desktop-integration, though none names it as a default-provider; after f-snap both theme snaps stayed, and the dry run plans the same | `snap connections gtk-theme-orchis`, Ubuntu Studio 26.04.1 VM |

## Carrying a snap profile over *(system verified 2026-10-14)*

| Finding | Source |
|---|---|
| Where each snap keeps its data on 26.04: Firefox in `$SNAP_USER_COMMON` (`~/snap/firefox/common/.mozilla`); Thunderbird and Element in the revision folder's `.config` (their `XDG_CONFIG_HOME`, `~/snap/<app>/<rev>/.config/...`). The `current` symlink is not always there, e.g. after `snap restore` | `snap run --shell <app>` in the GNOME VM |
| `snap remove` deletes `~/snap/<app>`; the data survives only in the automatic snapshot, so the copy must come first | GNOME VM |
| The debs use the legacy folder (`~/.mozilla`, `~/.thunderbird`) if it exists, otherwise the XDG one (`~/.config/mozilla`, `~/.config/thunderbird`) | GNOME VM, Firefox 158 and Thunderbird 158 started headless |
| A new install adopts the existing default profile only if its `compatibility.ini` says the same install last used it; otherwise it creates a new dedicated profile | support.mozilla.org/kb/understanding-depth-profile-installation |
| A copied snap profile names `/snap/<app>/<rev>/...`, so the deb made a new empty profile; with `LastPlatformDir`/`LastAppDir` pointed at `/usr/lib/<app>` the deb adopted the copy and kept its settings | GNOME VM, with a seeded snap profile |

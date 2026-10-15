# Changelog

All notable changes to f-snap are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and f-snap follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-15

### Added
- Swaps app snaps on Ubuntu 26.04 and its flavors where the replacement is better: Firefox and
  Thunderbird from Mozilla's APT repository, Element from Element's, Krita from Flathub. Ubuntu's
  own snap-only tools stay snaps, and snapd stays.
- Carries a snap's Firefox, Thunderbird or Element profile over to the new app, and points
  Mozilla profiles at the new installation so it opens them.
- Moves `/var/lib/snapd` and `/var/lib/flatpak` off the root partition by bind mount.
- Adds the vendor repositories to Ubuntu's automatic updates.
- Removes support snaps (bases, content and theme snaps) that no remaining snap uses.
- A dry run that changes nothing, a pre-flight that proves every replacement installs before any
  snap is removed, a log of every change, `verify-f-snap.sh`, and `undo-f-snap.sh`.
- `--stores-only`, automatic on systems that are not Ubuntu or a flavor.
- `--version`, and the version in `f-snap.log`.

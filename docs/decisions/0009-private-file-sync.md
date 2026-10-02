# 0009 - EA's private files sync between the mini and the laptop with Syncthing over Tailscale

Status: accepted 2026-10-02 (Michael: machines "Mini + laptop"; layout: "why does it need
restructuring?"; backup: "None right now. If at all, couldn't I just cloudflare R2 it for free?").

## Problem

Git syncs everything tracked in `~/Workspace`. EA's private files are git-ignored on purpose and
so exist on one machine only: `profile/health` (32 files), `profile/legal` (12) and
`business/keepthecall` (523), about 46 MB, all on the mini. The mini has no backup, and the laptop
copies were cleared on 2026-10-02. One disk failure loses them.

## Decision

- **Syncthing, Tailscale only.** Homebrew's `syncthing`, run as a LaunchAgent on the two opted-in
  machines (mini, laptop). Each listens only on its Tailscale address; global discovery, local
  discovery, relays, NAT traversal, usage reporting and auto-upgrade are off; the peer is
  addressed by its Tailscale IP. Nothing leaves the tailnet.
- **One folder: `~/Workspace/EA`, include-only.** Git carries EA; Syncthing carries only what git
  leaves out. A `.stignore` that dotfiles writes from one manifest list includes
  `profile/health`, `profile/legal` and `business/keepthecall` and ignores everything else (`*`),
  so Syncthing never reads or writes `.git` or a tracked file. No files move and no EA pointer
  changes. EA's `.gitignore` covers `.stignore`, `.stfolder` and `.stversions`.
- **Staggered versioning** on both machines (30 days), so an accidental delete or bad edit on one
  machine is recoverable from `.stversions` on the other.
- **Per-machine opt-in.** `~/.config/dotfiles/private-sync` turns it on (the same pattern as the
  ADR-0007 move gate); the peer list (name, Tailscale IP, Syncthing device ID) lives in the
  manifest. Device IDs identify a key, they are not secrets.
- **Converged by dotfiles.** `sync`/`setup` run a Python converger that sets the options, devices,
  folder and ignore list through Syncthing's local REST API; a second run changes nothing.

## Why not

- **Syncthing over all of `~/Workspace`:** two sync systems writing one repository fight over
  `.git` (index locks, refs, conflict copies) and over every tracked file git is mid-pull on.
- **A new `private/` folder:** cleaner for Syncthing, but it moves files the hub and EA's docs
  point at, for no gain once the include list works.
- **iCloud Drive:** it stalled for hours in both directions on 2026-10-02, and Desktop & Documents
  sync is what put conflict copies inside git repos before.

## Limits and later

- Not a backup: a deletion syncs. Versioning covers mistakes; a disk failure on both machines, or
  a theft of both, does not. If that changes: restic, encrypted on the mini, to a Cloudflare R2
  bucket (the free tier holds 10 GB; this set is 46 MB).
- The PC and WSL do not carry private files. The Windows side of the converger stays unwired until
  a Windows machine opts in (INV-2 exemption, named in the parity check).
- Syncthing writes conflict copies (`*.sync-conflict-*`) when both machines edit one file between
  syncs; they stay inside the ignored folders.

Enforcer: INV-24 (`scripts/ci/check-private-sync.py`).

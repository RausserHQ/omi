# Omi iOS fork workflow

`RausserHQ/omi` is a normal GitHub fork of `BasedHardware/omi`. The fork keeps
the upstream commit history. Keep `main` as the upstream mirror and put custom
work on branches so upstream syncs stay straightforward.

## Sync upstream

The local clone has `origin` set to `RausserHQ/omi` and `upstream` set to
`BasedHardware/omi`. To advance the fork when upstream changes, merge upstream
into a sync branch and open a merge-commit PR to `main`:

```bash
git fetch origin main
git fetch upstream main
git switch main
git merge --ff-only origin/main
git switch -c sync/upstream-2026-09-24 main
git merge --no-edit upstream/main
git push -u origin sync/upstream-2026-09-24
```

Replace the example date with a new date for each sync. Create a PR from that
branch to `main` and merge it with a merge commit. Keep iPhone-specific changes
on separate branches. After updating `main`, bring it into your branch with
`git rebase main` (for unpublished work) or `git merge main`. Ordinary `git
fetch`, `git merge`, and `git rebase` are all that is needed; no custom sync
tooling is required.

## Build and install on an iPhone

Use a Mac with Xcode 16.4 or newer, Flutter 3.44.5, and CocoaPods 1.16.2 or
newer. Connect and unlock the iPhone, enable Developer Mode, and use an Apple
development team that can sign the app. For the dev flavor, the app uses the
local development backend. Set `OMI_DEV_HOST` to an address reachable from the
phone (Mac LAN or Tailscale address). In one terminal, from the repository root,
start the local backend:

```bash
export OMI_DEV_HOST=192.168.1.20
make dev-up
```

In another terminal, run the profile build on the connected phone:

```bash
cd app
OMI_DEV_HOST=192.168.1.20 OMI_MOBILE_BUILD_MODE=profile bash setup.sh ios
```

The setup script prepares local Firebase configuration, Flutter codegen, CocoaPods,
and runs the app on the selected device. The profile build opens from the Home
Screen after installation. Replace the example host with the Mac's reachable
address.

## GitHub Actions artifact

The **iOS Build Artifacts** workflow runs on pushes to `main`, pull requests,
and manual dispatch. It builds the upstream `dev` flavor with local Firebase
fixtures and uploads the Xcode archive and build logs as the
`ios-build-<commit>` artifact. The artifact is unsigned and cannot be installed
directly. An installable IPA requires an Apple development certificate and
matching provisioning profiles; this fork currently has no signing secrets.

No capture, BLE, storage, transcription, or backend behavior is changed by this
fork setup.

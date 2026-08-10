# Granola for Linux with a macOS identity

An unofficial, source-only compatibility builder for running Granola's desktop
client on x86-64 Linux. It uses your own official Granola installer and account;
this repository does not contain or redistribute Granola.

Granola does not currently publish a Linux desktop client. Its
[official setup documentation](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time)
lists macOS, Windows, and iPhone. This project is experimental, unaffiliated
with Granola, and can stop working whenever Granola changes its desktop bundle.

## What it does

The builder combines Granola's application payload with the exact matching
official Linux Electron runtime, then rebuilds Granola's encrypted SQLite addon
for Linux.

The identity patch is deliberately split:

| Layer | Identity | Reason |
| --- | --- | --- |
| Renderer and Granola backend metadata | macOS / `darwin` | Gives Granola the requested product identity |
| Electron, Node native modules, and audio selection | Linux | Keeps Linux libraries, PipeWire/portal capture, and ELF modules working |

A global `process.platform = "darwin"` spoof is intentionally not used. That
would make Granola select CoreAudio, EventKit, Keychain, and other Mach-O-only
components that cannot run on Linux.

## Current status

Tested on Pop!_OS 24.04 with COSMIC/Wayland using Granola 7.469.1 and Electron
42.7.0.

| Capability | Status |
| --- | --- |
| App startup and login UI | Verified |
| Encrypted local SQLite storage | Verified, including Granola's custom update hook |
| Google login callback | Desktop protocol handler is installed by `desktop.sh`; test with your own account |
| Microphone capture | Permission flow and PipeWire stream verified; transcription still needs real-call testing |
| System/meeting audio | Onboarding fixed; uses Granola's built-in all-output-devices loopback path and still needs real-call testing |
| Global shortcuts | Limited on Wayland; Granola's bundle does not ship the Linux X11 key server |
| Google Meet consent helper | Unavailable; the official helper in the macOS installer is Mach-O-only |
| Self-update | Unavailable; rebuild from a new official DMG instead |

Do a disposable test meeting before relying on this for an important call.
Granola's web app can view and edit notes, but
[transcription is performed by the desktop client](https://docs.granola.ai/help-center/taking-notes/transcription).

## Requirements

- x86-64 Linux. ARM64 is not supported by this release.
- Your own Granola account and permission to use the downloaded client.
- Node.js `22.22.2+`, `24.15.0+`, or `26+`, plus npm.
- Python 3, curl, jq, tar, xz, make, `file`, and GCC/G++ 11 or newer.
- Normal Electron runtime libraries for your distribution, including GTK, NSS,
  GBM, and ALSA.

On Pop!_OS/Ubuntu, most build prerequisites can be installed with:

```bash
sudo apt install build-essential curl file jq make npm python3 xz-utils
```

Check `node --version` separately: the distribution's default Node.js may be too
old for the locked native-build toolchain.

## Build and install

```bash
git clone https://github.com/bindusara-reddy/granola-linux-macos.git
cd granola-linux-macos
./build.sh --download-latest --install-desktop
```

Or supply an official DMG you already downloaded:

```bash
./build.sh --install-desktop /path/to/Granola.dmg
```

The runnable app is created at `build/granola`. Start it from your application
launcher or run:

```bash
./build/granola/run-granola
```

Installing the desktop entry before signing in is important because it registers
the `granola://` callback used by browser-based authentication. The application
launcher is displayed simply as **Granola**; the compatibility details remain in
the entry's description and build metadata.

## Audio on Linux

Granola already contains a browser audio implementation for Linux. The patcher
preserves that branch even while the renderer-facing identity says macOS.

The current Granola bundle contains a Linux-specific Electron handler named
`loopbackAllDevices`. The patcher verifies and preserves its original audio-only
permission and capture requests. It does not add a display/video track: doing so
would conflict with Granola's audio-only handler and cause Chromium to reject the
request.

The builder also replaces one macOS-only microphone permission probe in
Granola's Linux browser-audio manager. Actual microphone access still goes
through Chromium's `getUserMedia` and PipeWire; the patch only prevents the
onboarding screen from treating Electron's unavailable Apple TCC API as a Linux
denial.

The project never adds `--no-sandbox` to the launcher.

[Electron display-media documentation](https://www.electronjs.org/docs/latest/api/session#sessetdisplaymediarequesthandlerhandler-opts)

## Updating and uninstalling

Update the builder and installed app with:

```bash
git pull --ff-only
./build.sh --download-latest --install-desktop
```

A completed build is staged on the destination filesystem before it is activated.
A recognized existing build is preserved next to the new one as
`granola.previous-<timestamp>` so an upstream breakage does not destroy the last
working copy.

Remove only the desktop integration with:

```bash
./desktop.sh uninstall
```

This does not delete generated builds or Granola's user data. Granola stores its
profile under `~/.config/Granola`; treat that directory as sensitive because it
can contain account and meeting metadata.

## Verification and failure behavior

The builder:

- downloads Granola only from Granola's official HTTPS endpoint;
- refuses redirects from HTTPS downloads to non-HTTPS protocols;
- records the DMG SHA-256 in the local build metadata;
- downloads the exact Electron version named by the installer and verifies it
  against Electron's official `SHASUMS256.txt`;
- verifies the pinned 7-Zip archive with SHA-256;
- verifies reviewed npm source tarballs with locked SHA-512 SRI values;
- performs only same-size ASAR patches and recalculates Electron's per-file ASAR
  integrity hashes;
- refuses to build if expected upstream code markers are missing or duplicated;
- compiles the native database addon and tests encryption, reopen, read/write,
  and the custom update hook before staging and replacing a working build;
- validates a new desktop entry before replacing the installed launcher.

The DMG itself is trusted through Granola's HTTPS download; this Linux workflow
does not validate Apple's code-signing chain. See [SECURITY.md](SECURITY.md) for
the full trust model.

## Legal and project scope

The MIT license in this repository covers only these scripts and documentation.
It does not cover Granola, Electron, generated application bundles, icons, or
third-party native modules. Do not upload or redistribute the generated build.
This tool does not bypass Granola login, subscriptions, or service-side access
controls. Review Granola's terms before use.

Thanks to the independent
[Granola-for-Linux](https://github.com/tirtha4/Granola-for-Linux) experiment for
demonstrating community interest in a Linux compatibility path. This project
uses a separate fail-closed patcher and split macOS/Linux identity design.

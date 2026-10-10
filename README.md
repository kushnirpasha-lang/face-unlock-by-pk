# Face ID for Mac · by PK

**Unlock your MacBook with your face using the built-in camera.** Open the lid or tap the trackpad → the screen
wakes → the camera recognizes you → the Mac unlocks. Touch ID and your password keep working the whole time.

A hardened fork of [jonnyoo/glance](https://github.com/jonnyoo/glance) (MIT, © Jonathan Zhou). Glance provides
the face recognition (ArcFace on the Neural Engine), liveness cues and the lock-screen overlay. This fork adds a
tested safety core, a Secure Enclave–backed password vault, strict rules for when the password may be typed, and
removes all networking.

> ⚠️ **Convenience, not a security upgrade.** A MacBook camera has no depth sensor, unlike Face ID on iPhone.
> Printed photos and phone screens are rejected. A replayed video of your face may not be. Keep Touch ID for
> anything that matters.

---

## How it works

```
screen locked ─► screen wakes / Space pressed ─► camera, 5 s window
   ─► frame quality gate ─► match against enrolled face + liveness
   ─► match? ─► injection guard: still locked? our session? nobody typing?
   ─► types the stored password ─► guard again ─► Return ─► verify the screen unlocked
```

macOS has no API that lets a third-party app log a user in. So, like every webcam face-unlock app, this one
**types your stored password into the lock screen** after a match. Everything below is about making that one action
as safe as possible.

## Design principles (and why)

Each rule answers a concrete problem found in upstream code, in review, or on a real Mac.

1. **Add, never replace.** No PAM modules, no authorizationdb, no login plugins, no loginwindow changes, no system
   files. If the app crashes, hangs or is deleted, the lock screen is exactly stock macOS. Touch ID and the keyboard
   work from the first millisecond, in parallel, not "after face fails".
2. **Never intercept input.** There is no `CGEventTap` in the code. Keyboard and trackpad are only *observed* through
   IOHID with `kIOHIDOptionsTypeNone`, so the app physically cannot swallow or delay a keystroke or click.
3. **A guard decides, twice: right before the text and right before Return.** The password is typed only if:
   - the screen is locked according to **both** CGSession and the lock/unlock notification (CGSession can lag
     hundreds of milliseconds after a Touch ID unlock);
   - the session on the console is **yours** (fast user switching would otherwise type it into someone else's login);
   - **you haven't pressed a key or clicked since the scan started** (the tap that woke the screen doesn't count);
   - Input Monitoring and Accessibility are granted. Without Input Monitoring the guard is blind, so nothing is typed.

   The password field is **never cleared**: upstream wiped whatever you had already started typing.
4. **Three attempts per lock, then silence.** After 3 failed attempts (configurable 1–5) the camera stays off until
   you unlock with Touch ID or your password. A failed attempt is a wrong face, a spoof, or a face that couldn't be
   confirmed. Not looking at the camera doesn't count.
5. **Locking never starts a scan.** Only a wake or the Space bar does. Upstream scanned on lock by default: you lock
   and walk away, your face is still in frame, and the Mac unlocks again.
6. **A wrong stored password is a sticky pause.** After typing, the app checks whether the screen actually unlocked.
   If not (for example, you changed your Mac password), face unlock turns off until you save the password again,
   even across restarts. Otherwise every lock would add a failed login attempt to your account.
7. **One injection at a time.** No new scan can start while a password is being typed; otherwise it could be typed
   twice.
8. **Zero network.** Sparkle and the upstream update feed are removed, so no other build can replace yours. CI fails
   the build if Sparkle or a feed URL reappears.
9. **Secure Enclave vault, no paid Apple account.** The key that encrypts your password and face data is wrapped by a
   P-256 key that lives inside the Secure Enclave (ECDH + HKDF-SHA256 + AES-GCM) and requires Touch ID or the login
   password to use. Upstream's keychain approach needs a paid Team ID; a self-signed build would fail with -34018.
10. **Bad frames don't count.** Two faces in frame → never unlock on that frame. Partial, turned (>25°), dark or blurry
    frames are skipped.
11. **Light liveness by default.** The strict mode (blink or head turn required) failed 5 of 6 self-tests on a real
    M1 MacBook Pro with a still, correctly recognized face. Light mode still rejects photos and phone screens. Strict
    mode is one click away.
12. **A pure core decides; a thin layer acts.** All rules above live in [`glance/Core`](glance/Core) as pure functions
    with no camera, screen or keyboard, covered by 33 unit tests (`swift test`) on every build. The app layer only asks
    the core for permission. Any doubt means "no".
13. **Exactly one copy runs.** A second launch (Launchpad, a copy on the DMG) just shows the first one's window and
    exits. The LaunchAgent restarts the app **only after a crash**, so ⌘Q really quits.
14. **Observable.** There is no menu-bar icon, so status, a "Test scanner" button and recent events live in the app
    window. The log (`~/Library/Logs/FaceIDforMac/events.jsonl`) records times, outcomes and numbers (similarity,
    frames skipped and why, liveness), never the password or camera frames.

The plan, the architecture and the code were each reviewed by an independent critic. The code review found and fixed
three real bugs: a double password injection, a Touch ID race, and a respawn after ⌘Q.

## Measured on an M1 MacBook Pro (macOS 26.5)

| | |
|---|---|
| Similarity to enrolled face | 0.85–0.87 (threshold 0.66) |
| Time to recognize | 0.3–1.3 s |
| Unlock from the lock screen | ✅ works (log: "face unlock — success") |
| Vault backend | Secure Enclave |

**Known issue:** the first scan right after wake sometimes ends as "spoof suspected" (30–40 glare/device cues in the
window), and the second scan passes immediately. Likely cause: the bright lock screen lighting the face triggers the
glare cue. Under investigation.

## What to watch out for

- **Ad-hoc signature.** Builds are signed ad-hoc (no Apple Developer account). macOS ties permissions to the exact
  build, so **after every update you re-grant** Camera, Accessibility and Input Monitoring. Stale entries can block the
  toggle; clear them with:
  `tccutil reset Accessibility com.pavel.faceidformac` (same for `Camera`, `ListenEvent`).
- **After a reboot,** the first login is always Touch ID or password (FileVault runs before any app). The app then
  needs one Touch ID to open its vault.
- **Gatekeeper.** First launch: System Settings → Privacy & Security → *Open Anyway*. Browsers may flag the download
  as dangerous because it isn't notarized.
- **Residual risk.** There are a few milliseconds between the guard's last check and the Return key. If you unlock with
  Touch ID exactly then, a Return could reach the app in focus. The password text itself is always guarded.
- **UI language.** The current build's interface is in Russian (the owner's build). All strings are plain Swift
  literals and are easy to translate.

## The app window

- **Home:** status, *Test scanner* (the camera looks at you; nothing is typed, the Mac is untouched), on/off,
  attempts, scan time, strictness, recent events, *Hide*, *Quit*, version, *by PK*.
- **Face:** enroll or re-enroll.
- **Password:** store or update the Mac password, confirm with Touch ID.

Version = commit time, e.g. `10.10.2026 18:15 · a1b2c3d`.

## Install

1. Download `Face-ID-for-Mac-<version>.dmg` from a [build run](../../actions/workflows/build.yml) (artifacts) and drag
   the app to Applications.
2. First launch → *Open Anyway* in Privacy & Security.
3. Grant Camera, Accessibility, Input Monitoring and Notifications.
4. Enroll your face, store your Mac password, confirm with Touch ID.

**Uninstall:** `bash pk/uninstall.sh` removes the app, its LaunchAgent, data, log and granted permissions.

**Requirements:** macOS 15+, a Mac with Touch ID and a Secure Enclave. Tested on Apple Silicon (M1).

## Build

GitHub Actions on `macos-26` (Xcode 26):
1. `swift test` for the safety core.
2. Unsigned `xcodebuild`.
3. Binary checks: no Sparkle, no update feed.
4. Ad-hoc signature with the hardened runtime and a camera-only entitlement.
5. DMG artifact.

## Credits

*by PK* · based on [Glance](https://github.com/jonnyoo/glance) by Jonathan Zhou, MIT License. The upstream README is
kept below.

---

<details>
<summary>Original Glance README (upstream)</summary>


<h1 align="center">
  <br>
  <a href="https://tryglance.app"><img src="glance/Assets.xcassets/appicon.imageset/appicon.png" alt="Glance" width="150"></a>
  <br>
  Glance
  <br>
</h1>

<h3 align="center">Face unlock for your Mac</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-black.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black.svg" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-black.svg" alt="Swift">
</p>

Glance brings the FaceID-like experience of your iPhone to a Mac near you. Unlock your Mac with a glance — no typing, no reaching for the TouchID key. Everything runs on-device using Apple's Vision
and Core ML frameworks, so your face data and your Mac password never touch the internet. The UI is built into your Macbook's notch with fluid dynamic island like animations.


https://github.com/user-attachments/assets/77438826-80a9-4ab2-9fc3-42407a2d0adb


---

> [!WARNING]
> ## Read before downloading
> ## Glance is not as secure as Apple's FaceID or TouchID
> 
> MacBooks don't come equipped with the depth sensors that make iPhone FaceID trustworthy and secure. An
> iPhone builds a 3D map of your face; a MacBook webcam sees a flat 2D image. That means:
> 
> - Glance defeats, with reasonable confidence, a printed photo and a photo on a phone screen (heavy liveness detection must be turned on)
> - Glance does not reliably defeat a video of you
> - macOS has no API that lets a third-party app authorize a login, so Glance unlocks by typing
>   your stored password on the lock screen
> 
> Glance is a convenience feature, not a security upgrade. Only continue if you accept the tradeoff.

## Installation

**Requirements:**
- macOS 15 Sequoia or later
- Apple Silicon or Intel Mac

<a href="https://github.com/jonnyoo/glance/releases/latest/download/Glance.dmg" target="_self"><img width="200" src="https://github.com/user-attachments/assets/cdb8af97-1ee2-4669-b7cb-dcfb56c9dd61" alt="Download for Mac" /></a>

Open the `.dmg` file and drag Glance to `/Applications`, then open it.


## Permissions

| Permission | Why |
|---|---|
| **Camera** | To see your face. Frames are processed in memory and never written to disk. |
| **Accessibility** | To type your password into the lock screen. |
| **Touch ID** | Gates the key that encrypts your face data and password. |

## How it works

1. Launch the app and follow the onboarding to enroll your face. Glance guides you through capturing your face, turning your head in nine
   directions. Each frame becomes a 512-number *embedding* — a mathematical fingerprint — and the
   image is thrown away.
2. Enter your Mac password once, encrypted behind Touch ID.
3. When your Mac locks or wakes from sleep, the animation appears in the notch and starts searching for a face.
4. If it's you — and the liveness checks agree you're a real person — Glance types the
   password and you're in.

## Features

| Feature | Description |
|---|---|
| **Face unlock** | Triggers on wake, on lock, or on pressing space at the lock screen. Pick any combination. |
| **Multiple identities** | Enroll several people, or several versions of yourself — with glasses, a beard, different lighting. Toggle any of them off without deleting. |
| **Liveness checks** | Watches for the motion and reflections that separate a real face from a photo. *Light* or *Heavy* strictness, or off. |
| **Notch UI** | A closed pill that expands into a scan animation with success and failure states. Hover to retry — or turn animations off entirely and Glance stays invisible. |
| **Camera & display** | Choose which camera to use, including different cameras for the built-in display vs. an external monitor. |
| **Auto-locking sessions** | The Touch ID session re-locks itself after an idle period you choose, so an unattended Mac doesn't stay authorized forever. |
| **Trackpad haptics** | Hovering over the notch will trigger haptics |
| **Notchless Mac support** | Macs without a notch will be replaced with a pill-shape, dynamic island style design. |
| **Your data, your call** | Edit or delete your enrolment or stored password at any time. The encrypted files are removed immediately. |

---

# Privacy and Security

Glance is designed to keep biometric data and credentials on-device.

### Face data

Glance never stores camera images. During enrollment, each captured face is converted into a **512-dimensional embedding** using an ArcFace-based Core ML model. The original frame is then discarded.

Embeddings are stored locally and encrypted with **AES-GCM**.

### Credentials

Your Mac password is stored as encrypted data and is never written to disk in plaintext. The encryption key is a **256-bit AES key stored in the macOS Keychain**, protected by `userPresence` — requiring Touch ID or your device password.

The key is only held in memory while an authorized Glance session is active.

### Unlock pipeline

Glance won't type your password simply because a face matches. An unlock requires all of the following:

1. A valid Glance session is authorized.
2. The Mac is actually at the lock screen.
3. An enabled identity matches above the configured similarity threshold.
4. Liveness checks accept the detected face.
5. Accessibility permission is available to enter the password.

Face recognition and liveness detection run independently and must both succeed before the password is entered. 

### Local by design

Face recognition, face enrollment, and liveness detection run entirely on-device using Vision and Core ML. Glance does not send face data, camera frames, or credentials to a server.


### How it tells a face from a photo

Five independent cues over a rolling ~2s window, in two roles:

- **Deny cues** are evidence of a spoof — screen glare, or a device-shaped rectangle framing the
face. Either one fails the scan outright and overrides anything else.
- **Confirm cues** are evidence of a real face — flat-vs-3D landmark geometry, nose parallax
across head turns, blinks. Any one is enough, and their absence is never a failure, since a
live person can sit still and not blink.

Light detection only include deny cues. Heavy detection includes both deny and confirm cues.

### Face Lab

Face Lab is a hidden debug console to test face recognition and liveness detection with real values.

**To open it:** Settings → About, then click the app icon 5 times. A
debug section should appear in the sidebar.

---


## Building from source

### Prerequisites

- macOS 15+
- Xcode 26+



### Installation

1. Clone repository:
  ```bash
   git clone https://github.com/jonnyoo/glance.git
   cd glance
  ```
2. Open in Xcode:
  ```bash
   open glance.xcodeproj
  ```
3. Run the project:
  - Click `run` or press `Cmd + R`.



## Contributing

Not currently accepting PRs. Feel free to fork this project.

App feedback goes to [tryglance.app/feedback](https://tryglance.app/feedback).

## Acknowledgements

- **[The Boring Notch](https://github.com/TheBoredTeam/boring.notch)** — for the notch window
physics.
- **[InsightFace](https://github.com/deepinsight/insightface)** — the ArcFace model doing the
recognition.
- **[Alcove](https://tryalcove.com)** — big design inspiration.


## License

[MIT](LICENSE) © Jonathan Zhou

</details>

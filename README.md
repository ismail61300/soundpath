# SoundPath

A free, open-source volume mixer for the Mac menu bar. Set the volume of every app separately, add
effects, and route apps to different outputs. No account, no tracking, no third-party code.

## Features

- **Per-app channel strips**: a vertical fader, mute, level meter and output redirect for each app that
  plays sound. Pin favourites so they stay in the mixer.
- **System strips**: output, input and system-sound volume with device pickers and live meters.
- **Effects** for any app or the master output: Volume Overdrive (peak-limited), 10-band parametric EQ
  (presets, AutoEQ / Equalizer APO import), Boost (dynamics), output Balance.
- **Audio Devices window**: nicknames, icons, hide, max volume, channel routing, sample rate.
- Optional update check against GitHub Releases (off by default).
- Global show/hide shortcut, optional Super Volume Keys (media keys control the output volume),
  light/dark theme, accent colour, 3–5 faders per row, 11 languages, first-launch tour.

Requires macOS 15 or later.

## Install

1. Download `SoundPath.dmg` from the [latest release](https://github.com/ismail61300/soundpath/releases/latest)
   and drag SoundPath to Applications.
2. Follow the tour; the last page asks for the audio permission.

Releases are signed with a Developer ID certificate and notarized by Apple, so macOS opens them normally
and keeps the permissions across updates.

## Permissions

| Permission | Why |
| --- | --- |
| Audio capture (system audio) | Required for per-app volume and effects. |
| Microphone | Only to show the live input level, while a panel is on screen. |
| Accessibility | Only for Super Volume Keys (media-key tap). Optional. |

SoundPath never records or stores audio. Its only network request is the optional update check
(Settings → Updates): one HTTPS call to the GitHub releases API, when you press *Check Now* or, if you
turned it on, once a day. Nothing is sent besides the request itself, and nothing is downloaded or
installed automatically.

## How it works, and its limits

Per-app control uses Core Audio process taps (`CATapDescription`). Two private system interfaces are
used: the TCC framework (to read the audio-capture permission state, which has no public API) and
`responsibility_get_pid_responsible_for_pid` (to group helper processes under their app, e.g. Safari).
Because of this the app cannot ship on the Mac App Store, and a future macOS release may break them.
Please open an issue if something stops working after an update.

## Build

```sh
brew install xcodegen
xcodegen generate          # creates SoundPath.xcodeproj from project.yml (not committed)
open SoundPath.xcodeproj   # ⌘R
```

Run `xcodegen generate` again after pulling changes that add files.
Tests: `⌘U`, or `xcodebuild -project SoundPath.xcodeproj -scheme SoundPath -destination 'platform=macOS' test`.

`tools/release.sh` runs the tests, builds Release, signs, notarizes, and writes `dist/SoundPath.dmg`. With a
"Developer ID Application" certificate in the keychain it signs with it; to notarize, store credentials once:

```sh
xcrun notarytool store-credentials soundpath-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
```

## Translations

UI strings live in `SoundPath/Resources/<lang>.lproj/Localizable.strings` (en, tr, zh-Hans, hi, es, fr,
ar, bn, pt-BR, ru, ur). English is the reference; keep the same keys in every file. Most non-English
strings are machine translated: corrections by native speakers are very welcome.

## App icon

`python3 tools/make_icon.py` (needs Pillow) draws the base artwork; the shipped icon set is in
`SoundPath/Assets.xcassets/AppIcon.appiconset`.

## Layout

```
SoundPath/App       app delegate, menu-bar panel, hot keys, media keys
SoundPath/Audio     taps, engine hosts, effect chains, device model
SoundPath/Model     mixer model, settings, preferences
SoundPath/UI        SwiftUI views (panel, FX, EQ, Settings, tour, Audio Devices)
SoundPath/Resources localized strings
```

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)

SoundPath is an independent, free, non-commercial open-source project. It is not affiliated with, or endorsed
by, any company or product with a similar name. All product names mentioned belong to their owners.

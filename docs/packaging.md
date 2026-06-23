# AgentBeacon Packaging

Lite currently ships as a SwiftPM-built menu bar app bundle.

## Local App Bundle

```bash
./scripts/build-app.sh
open build/AgentBeacon.app
```

The script creates:

```text
build/AgentBeacon.app
```

It copies the release executable plus the SwiftPM resource bundle containing
mascots, menu bar icons, and sounds.

## Sparkle Roadmap

Sparkle is intentionally not linked yet. The next production step is:

- add Sparkle as an app-bundle dependency, not to the plain SwiftPM debug run
- add `SUFeedURL` and signing keys to `Info.plist`
- generate an appcast in release automation
- sign and notarize the `.app` / `.dmg`

Until then, `build-app.sh` is suitable for local smoke testing only.

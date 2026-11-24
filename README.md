# Ntonia-PreferenceLoader

PerfectGrabber jailbreak tweak source. GitHub Actions builds rootless and RootHide packages on a native macOS runner with Apple clang/linker. Push to `main` to start a build. The repository owner's fine-grained token must allow Actions to run on pushes.

The workflow verifies the tweak and Preferences bundle each contain native arm64 and arm64e slices before uploading artifacts.

## Pull-down card

The pull-down card shows time, battery level/charging state, battery temperature, media artwork/title and current status. Long-pressing the card opens the playback panel, which docks to the top safe edge instead of floating in the center. Lyrics integration and configurable blur/opacity controls are not implemented yet.

Minimum deployment target: iOS 15.0.

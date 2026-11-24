# Ntonia-PreferenceLoader

PerfectGrabber jailbreak tweak source.

## Build

The repository uses GitHub Actions on macOS and the native Apple/Clang linker. Push to `main` or manually run **Build DEB** to produce rootless and RootHide packages.

The workflow verifies that both the tweak and its Preferences bundle contain native `arm64` and `arm64e` slices before publishing the artifacts. The iOS deployment target is 15.0.

## Pull-down card

Shows time, battery percentage/charging state, battery temperature and current media artwork/title. Long-pressing the card opens the existing playback controls panel. Lyrics integration and configurable blur/opacity controls are not included yet.

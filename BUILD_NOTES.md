# 1.1-57 capsule/settings stability update

- Reuses one PGGrabberOverlayView as a child of the original SBGrabberTongue host while the pull-down is open; the card switches to a small in-place status + short-track pill and long-press expands the same view to artwork/title/artist/controls/seek slider.
- Saves/restores the original grabber frame and ancestor clips-to-bounds when the user explicitly taps X.
- Long press is deferred against ancestor tap recognizers and guarded in `_willDismiss`; an expanded view remains on the grabber. When the native pull-down is dismissed while not held, the same card view is moved into a touch-through edge container in the same SpringBoard window; it remains until X is tapped.
- Adds MediaRemote elapsed-time seeking. The Settings controller deliberately avoids a custom table-cell display hook after the previous version caused an immediate crash on-device; slider haptics are temporarily omitted to keep the preferences page stable.

The settings bundle reads SliderHaptics directly with CFPreferences; it does not reference the tweak-only PerfectGrabberPreferences Objective-C class. This avoids the flat-namespace missing-class load error on iOS.

Validation is static source syntax only. Do not describe as device-tested until checked on iPhone 14 Pro Max / iOS 16.3.1 / Dopamine RootHide. The macOS GitHub Actions build is the source of the installable RootHide package.

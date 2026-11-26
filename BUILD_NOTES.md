# 1.1-55 capsule-card update

- Reuses one PGGrabberOverlayView as a child of the original SBGrabberTongue host while the pull-down is open; the card switches to a small in-place status + short-track pill and long-press expands the same view to artwork/title/artist/controls/seek slider.
- Saves/restores the original grabber frame and ancestor clips-to-bounds when the user explicitly taps X.
- Long press is deferred against ancestor tap recognizers and guarded in `_willDismiss`; an expanded view remains on the grabber. When the native pull-down is dismissed while not held, the same card view is moved into a touch-through edge container in the same SpringBoard window; it remains until X is tapped.
- Adds MediaRemote elapsed-time seeking and optional step-based Settings slider haptics.

Validation is static source syntax only. Do not describe as device-tested until checked on iPhone 14 Pro Max / iOS 16.3.1 / Dopamine RootHide. The macOS GitHub Actions build is the source of the installable RootHide package.

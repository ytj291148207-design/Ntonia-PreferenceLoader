# GrabberCard RootHide build

This folder contains the uploaded GrabberCard source and a macOS GitHub Actions build for an arm64 + arm64e RootHide package.

The workflow builds both slices with Apple's iPhoneOS 16.5 SDK, packages the rootless staging tree, converts it to RootHide's root-level payload layout, rewrites load paths, re-signs, and checks package metadata, architectures, and residual `/var/jb` dynamic dependencies.

GitHub Actions output is a statically checked DEB artifact. No claim of installation or runtime validation on the target device is made.

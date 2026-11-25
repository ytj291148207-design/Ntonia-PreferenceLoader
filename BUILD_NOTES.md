# 1.1-54 RootHide build note

This revision is intended to be built by the GitHub Actions macOS workflow in this repository. The workflow builds universal arm64/arm64e rootless output and repacks it as a RootHide `iphoneos-arm64e` package using Apple's native Xcode linker/tooling. Do not reuse manually linked iSH arm64e binaries; the previous manual ld64.lld attempt produced an invalid dyld bind stream.

The authoritative installable RootHide deb is the `*_roothide.deb` artifact from the successful GitHub Actions run. It has not been installed/device-validated yet.

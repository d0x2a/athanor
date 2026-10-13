# Sourced by run-dev.sh, build-release.sh and build-appstore.sh: flags every
# `swift build` of the app takes. Not meant to be run on its own.
#
# SwiftPM links with clang --sysroot, and without -isysroot clang can't read
# the SDK's version, so the binaries record the deployment target (14.0) as
# the SDK they were built with. macOS keys newer behavior to that version, and
# App Store Connect won't process a build made with an SDK that old. Passing
# -isysroot to the link records the real one; bundle.sh checks it did.

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_FLAGS=(
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH"
)

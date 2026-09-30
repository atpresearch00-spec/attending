# Sourced by build/test scripts. Newer Command Line Tools SDKs implement SwiftUI's
# @State as a macro whose compiler plugin only ships with full Xcode. Without that
# plugin, build against the newest installed macOS 26 SDK instead.
if [[ -z "${SDKROOT:-}" && ! -e /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib && ! -d /Applications/Xcode.app ]]; then
  fallback=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.[0-9]*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$fallback" ]] && export SDKROOT="$fallback"
fi

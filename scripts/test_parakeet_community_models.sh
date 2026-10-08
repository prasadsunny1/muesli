#!/usr/bin/env bash
set -euo pipefail

# Compile the app's actual Parakeet backend without the unrelated MLX/LiteRT
# dependencies. This checks inference, not GUI, dictation capture, or meetings.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 1 || "$1" == "--help" ]]; then
  echo "Usage: $0 <audio.wav | --test-only>"
  echo "Downloads Redux and Ultra into the app's shared FluidAudio model cache."
  echo "Requires macOS 14.2+ and Swift 6.0+ (Redux requires macOS 15+)."
  [[ $# -eq 1 && "$1" == "--help" ]] && exit 0
  exit 2
fi

if [[ "$1" != "--test-only" && ! -f "$1" ]]; then
  echo "Audio file does not exist: $1" >&2
  exit 2
fi

PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muesli-parakeet-smoke.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
mkdir -p "$PACKAGE_DIR/Sources/MuesliCore" "$PACKAGE_DIR/Sources/MuesliNativeApp" \
  "$PACKAGE_DIR/Tests/MuesliTests"
for file in ManagedASRModelDownloads ModelDownloadCoordinator HuggingFaceModelManifestResolver \
  MuesliModelMirrorManifestResolver MuesliPaths; do
  ln -s "$ROOT/native/MuesliNative/Sources/MuesliCore/$file.swift" "$PACKAGE_DIR/Sources/MuesliCore/"
done
ln -s "$ROOT/native/MuesliNative/Sources/MuesliNativeApp/FluidAudioBackend.swift" "$PACKAGE_DIR/Sources/MuesliNativeApp/"
# Compile the executable in the same module as the internal app backend.
ln -s "$ROOT/scripts/parakeet-community-smoke/Smoke.swift" "$PACKAGE_DIR/Sources/MuesliNativeApp/"
ln -s "$ROOT/native/MuesliNative/Tests/MuesliTests/ModelDownloadCoordinatorTests.swift" "$PACKAGE_DIR/Tests/MuesliTests/"
cat > "$PACKAGE_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ParakeetCommunitySmoke",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "parakeet-community-smoke", targets: ["MuesliNativeApp"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")],
    targets: [
        .target(name: "MuesliCore"),
        .executableTarget(name: "MuesliNativeApp", dependencies: ["MuesliCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "MuesliTests", dependencies: ["MuesliCore"]),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
SCRATCH_PATH="${MUESLI_PARAKEET_SMOKE_SCRATCH_PATH:-$HOME/Library/Caches/muesli-spm/parakeet-community-smoke}"
if [[ "$1" == "--test-only" ]]; then
  swift test --package-path "$PACKAGE_DIR" --scratch-path "$SCRATCH_PATH" -j 4
  swift run --package-path "$PACKAGE_DIR" --scratch-path "$SCRATCH_PATH" -j 4 parakeet-community-smoke --check
else
  swift run --package-path "$PACKAGE_DIR" --scratch-path "$SCRATCH_PATH" -j 4 parakeet-community-smoke "$1"
fi

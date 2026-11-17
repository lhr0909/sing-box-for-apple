#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
    echo "Usage: $0 CORE_REPOSITORY CORE_COMMIT OUTPUT_DIRECTORY" >&2
    exit 2
fi

apple_dir="$(cd "$(dirname "$0")/.." && pwd)"
core_dir="$(cd "$1" && pwd)"
core_commit="$(git -C "$core_dir" rev-parse --verify "$2^{commit}")"
mkdir -p "$3"
output_dir="$(cd "$3" && pwd)"
if [[ -n "$(ls -A "$output_dir")" ]]; then
    echo "Output directory must be empty: $output_dir" >&2
    exit 1
fi
command -v go >/dev/null
command -v xcodebuild >/dev/null

# Build an immutable snapshot: never consume another agent's uncommitted work,
# or let build_libbox move its output into a sibling client checkout.
source_dir="$output_dir/core-source"
mkdir "$source_dir"
git -C "$core_dir" archive "$core_commit" | tar -x -C "$source_dir"
git -C "$core_dir" show -s --format=%cI "$core_commit" > "$output_dir/core-commit-date.txt"
printf '%s\n' "$core_commit" > "$output_dir/core-commit.txt"
git -C "$apple_dir" rev-parse HEAD > "$output_dir/apple-commit.txt"
go version > "$output_dir/go-version.txt"
xcodebuild -version > "$output_dir/xcode-version.txt"

# Keep mobile executables private; allow the normal, concurrency-safe Go module
# and compilation caches to be reused across baseline and feature builds.
export GOMODCACHE="${GOMODCACHE:-$(go env GOMODCACHE)}"
export GOPATH="$output_dir/gopath"
export GOTOOLCHAIN=local
unset GOBIN
export PATH="$GOPATH/bin:$PATH"
(
    cd "$source_dir"
    make lib_install
    go run ./cmd/internal/build_libbox -target apple -platform ios/arm64
) > "$output_dir/libbox-build.log" 2>&1
mv "$source_dir/Libbox.xcframework" "$output_dir/Libbox.xcframework"
(
    cd "$output_dir"
    find Libbox.xcframework -type f -exec shasum -a 256 {} \; | LC_ALL=C sort > Libbox.sha256
)

# This is the existing, ignored Xcode input. Replace the whole framework so a
# previous simulator/device slice cannot silently survive the new build.
if [[ -L "$apple_dir/Libbox.xcframework" ]]; then
    echo "Refusing to replace a symlink at Libbox.xcframework" >&2
    exit 1
fi
rm -rf "$apple_dir/Libbox.xcframework"
ditto "$output_dir/Libbox.xcframework" "$apple_dir/Libbox.xcframework"
(
    cd "$apple_dir"
    shasum -a 256 -c "$output_dir/Libbox.sha256"
) > "$output_dir/framework-verification.log"

# This small, dependency-free check still verifies the generated Swift bridge
# if unrelated application packages prevent the full SFI build from starting.
cat > "$output_dir/libbox-smoke.swift" <<'SWIFT'
import Foundation
import Libbox

func validateProfile(_ content: String) throws {
    var error: NSError?
    LibboxCheckConfig(content, &error)
    if let error { throw error }
}
SWIFT
xcrun swiftc -typecheck -target arm64-apple-ios15.0 \
    -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -F "$output_dir/Libbox.xcframework/ios-arm64" \
    "$output_dir/libbox-smoke.swift" > "$output_dir/libbox-smoke.log" 2>&1

xcode_args=(-project "$apple_dir/sing-box.xcodeproj" -scheme SFI
    -configuration Debug -destination 'generic/platform=iOS'
    -derivedDataPath "$output_dir/DerivedData"
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build)
if [[ -n "${SFI_SOURCE_PACKAGES:-}" ]]; then
    xcode_args+=(-clonedSourcePackagesDirPath "$SFI_SOURCE_PACKAGES")
fi
xcodebuild "${xcode_args[@]}" > "$output_dir/sfi-build.log" 2>&1
echo "Unsigned SFI build completed: $output_dir"

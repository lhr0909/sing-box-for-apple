# Build SFI with a specific core commit

SFI links `Libbox.xcframework` at this repository's root. Checking out a sibling
sing-box repository does not update that library. Protocol support comes from
the core compiled into the framework; no client UI change is needed for Snell
v2/v3 profiles.

Use the Go version from the selected core's Apple CI and the iOS ARM64 CPU patch
in that core's `.github/patch_go_for_ios.sh`. Apply the patch to a private Go
installation, since it modifies GOROOT. Install Xcode and initialize Runestone:

```sh
git submodule update --init Frameworks/Runestone
```

Then build an exact committed core snapshot and compile SFI:

```sh
./script/build_sfi.sh /path/to/sing-box CORE_COMMIT /path/to/empty/output-directory
```

The script uses the core's `make lib_install` and `build_libbox` entrypoints,
including their normal Tailscale and protocol build tags. It builds only the
`ios/arm64` device slice, replaces the ignored root `Libbox.xcframework`, verifies
its SHA-256 hashes, typechecks the Swift configuration-validation bridge, then
builds SFI for generic iOS with signing disabled. It
does not install or launch the app. Signing, provisioning and device acceptance
require separate validation.
Swift packages use the committed `Package.resolved` versions without updating
remote branches.

Output includes the core and Apple commit IDs, toolchain versions, framework
hashes, native/Swift/Xcode build logs, and DerivedData. Use a new empty output
directory for each run. `SFI_SOURCE_PACKAGES` can point to an external Xcode
package cache. Native compilation runs in an archived source directory and
does not write to the shared core checkout. The archive has no Git metadata, so
the embedded version can be `unknown`; use `core-commit.txt` to identify it.
Framework staging and SFI compilation hold `build/libbox-sfi.lock` so concurrent
script invocations cannot overwrite each other's Xcode input. A conflicting
invocation keeps its completed library in the output directory and exits.

Snell v2 provides TCP only. Snell v3 also supports UDP over TCP. These build
checks establish compilation against a particular library, not interoperability
with a live proxy or installation readiness.

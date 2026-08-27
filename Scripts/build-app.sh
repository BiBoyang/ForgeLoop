#!/usr/bin/env bash
# Assemble ForgeLoop.app — a real macOS application bundle with the embedded
# Sparkle.framework that powers in-app auto-update.
#
# ForgeLoopApp is a plain SwiftPM executable; `swift run` produces a bare binary
# with no bundle. This script builds the release binary and wraps it in a `.app`
# bundle (Info.plist + executable), then embeds Sparkle (which SwiftPM links but
# does NOT bundle on its own) under Contents/Frameworks.
#
# The release bundle is universal (arm64 + x86_64) so one DMG runs on Apple
# silicon and Intel Macs alike. Pass --host-only for a faster local build.
#
# Usage:
#   ./Scripts/build-app.sh                          # universal, ad-hoc signed
#   ./Scripts/build-app.sh --host-only              # host arch only, ad-hoc
#   ./Scripts/build-app.sh --sign "Developer ID Application: Name (TEAMID)"
#   open ./ForgeLoop.app
#
# Options / environment:
#   --sign IDENTITY    codesign identity (default: "-" ad-hoc, for local use).
#                      Env override: SIGN_IDENTITY.
#   --version X.Y.Z    CFBundleShortVersionString (env: FORGELOOP_VERSION).
#   --build N          CFBundleVersion; must increase across shipped builds
#                      because Sparkle compares it (env: FORGELOOP_BUILD).
#   --host-only        build only the host architecture.
#
# NOTE on SwiftPM resource bundles: this script copies *.bundle products into
# Contents/Resources, but a dependency that reads its own `Bundle.module` will
# still crash — `swift build` bakes that accessor with the .app ROOT plus a
# hardcoded build-machine path, never Contents/Resources. ForgeLoop's only
# external dependency (ForgeLoopTUI) ships no resources, so this is latent; if
# a resource-carrying dependency is ever added, vendor it or patch the lookup
# before shipping (the termio v0.2.4 lesson).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

product_name="ForgeLoopApp"
app_name="ForgeLoop"
app_dir="$repo_root/${app_name}.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
frameworks_dir="$contents_dir/Frameworks"

sign_identity="${SIGN_IDENTITY:--}"
version="${FORGELOOP_VERSION:-}"
build_number="${FORGELOOP_BUILD:-}"
host_only=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)
            sign_identity="$2"
            shift 2
            ;;
        --version)
            version="$2"
            shift 2
            ;;
        --build)
            build_number="$2"
            shift 2
            ;;
        --host-only)
            host_only=1
            shift
            ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1' (see --help)" >&2
            exit 1
            ;;
    esac
done

# Build one slice per Mac architecture, then lipo them together. SwiftPM's own
# multi-arch mode (--arch arm64 --arch x86_64) routes through the Xcode build
# system; one --arch at a time keeps the normal one. Only the executable
# differs between slices — Sparkle.framework ships universal from its
# xcframework, resource bundles are arch-independent.
architectures=(arm64 x86_64)
[[ "$host_only" == "1" ]] && architectures=("$(uname -m)")

slice_binaries=()
bin_path=""
for arch in "${architectures[@]}"; do
    echo "==> Building $app_name (release, $arch)"
    swift build -c release --arch "$arch"

    slice_bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
    slice_binary="$slice_bin_path/$product_name"
    if [[ ! -x "$slice_binary" ]]; then
        echo "error: built $arch binary not found at $slice_binary" >&2
        exit 1
    fi
    slice_binaries+=("$slice_binary")
    [[ -n "$bin_path" ]] || bin_path="$slice_bin_path"
done

sparkle_src="$bin_path/Sparkle.framework"
if [[ ! -d "$sparkle_src" ]]; then
    echo "error: Sparkle.framework not found at $sparkle_src — did the SPM build run?" >&2
    exit 1
fi

echo "==> Assembling bundle at $app_dir"
rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$frameworks_dir"
lipo -create "${slice_binaries[@]}" -output "$macos_dir/$product_name"
chmod +x "$macos_dir/$product_name"
cp "$repo_root/packaging/Info.plist" "$contents_dir/Info.plist"

# Fail loudly rather than shipping a DMG an arch refuses to open.
bundled_archs="$(lipo -archs "$macos_dir/$product_name")"
for required_arch in "${architectures[@]}"; do
    if [[ " $bundled_archs " != *" $required_arch "* ]]; then
        echo "error: bundled binary is missing the $required_arch slice — has [$bundled_archs]" >&2
        exit 1
    fi
done
echo "==> Bundled binary architectures: $bundled_archs"

echo "==> Bundling SwiftPM resource bundles"
shopt -s nullglob
for resource_bundle in "$bin_path"/*.bundle; do
    cp -R "$resource_bundle" "$resources_dir/"
done
shopt -u nullglob

# Stamp version / build number when supplied (the release workflow does).
plist="$contents_dir/Info.plist"
if [[ -n "$version" ]]; then
    echo "==> Stamping CFBundleShortVersionString=$version"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
fi
if [[ -n "$build_number" ]]; then
    echo "==> Stamping CFBundleVersion=$build_number"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
fi

echo "==> Embedding Sparkle.framework"
cp -R "$sparkle_src" "$frameworks_dir/"
# SwiftPM links @rpath/Sparkle.framework with only an @loader_path rpath, which
# would look beside the binary. Point @rpath at Contents/Frameworks so the
# embedded copy is found at runtime. (Harmless if the entry already exists.)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$macos_dir/$product_name" 2>/dev/null || true

# Sign inside-out. A Developer ID identity (with the hardened runtime) makes the
# bundle notarizable; the default "-" ad-hoc identity is enough for local runs.
# Either way Sparkle's nested helpers must be sealed before the framework, and
# the framework before the outer app, or codesign rejects the bundle.
sign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi

echo "==> Signing with identity: $sign_identity"
sparkle="$frameworks_dir/Sparkle.framework"
sparkle_version="$(readlink "$sparkle/Versions/Current" || echo B)"
sparkle_v="$sparkle/Versions/$sparkle_version"
for component in \
    "$sparkle_v/XPCServices/Installer.xpc" \
    "$sparkle_v/XPCServices/Downloader.xpc" \
    "$sparkle_v/Autoupdate" \
    "$sparkle_v/Updater.app"; do
    [[ -e "$component" ]] && codesign "${sign_args[@]}" "$component"
done
codesign "${sign_args[@]}" "$sparkle"
# Seal the outer app last so CodeResources covers the embedded framework. NOT
# --deep: the framework's components are already individually signed above.
codesign "${sign_args[@]}" "$app_dir"
# Not --deep here either: Apple deprecated it for verification, and it does not
# check nested code the way the name suggests. --strict is what does.
codesign --verify --strict --verbose=2 "$app_dir"

echo "==> Done: $app_dir"
echo "    Launch with:  open \"$app_dir\""

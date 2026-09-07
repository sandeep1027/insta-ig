#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:?usage: stage-sparkle-bundle.sh <destination> [--localizations-only|--augment-ffmpeg|--frameworks-only]}"
MODE="${2:-}"

# Theos's Linux iOS toolchain provides otool/install_name_tool/ldid.
if ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1; then
    THEOS_BIN="${THEOS:-$HOME/theos}/toolchain/linux/iphone/bin"
    if [ -d "$THEOS_BIN" ]; then
        export PATH="$THEOS_BIN:$PATH"
    fi
fi

plistbuddy() {
    if [ -x /usr/libexec/PlistBuddy ]; then
        /usr/libexec/PlistBuddy "$@"
    else
        python3 "$ROOT_DIR/tools/plistbuddy.py" "$@"
    fi
}

sparkle_codesign_sign() {
    local binary="$1"
    local identifier="${2:-}"
    if command -v codesign >/dev/null 2>&1; then
        if [ -n "$identifier" ]; then
            codesign --force --sign - --timestamp=none --identifier "$identifier" "$binary"
        else
            codesign --force --sign - --timestamp=none "$binary"
        fi
        return
    fi
    if [ -n "$identifier" ]; then
        ldid -S -I"$identifier" "$binary"
    else
        ldid -S "$binary"
    fi
}

sparkle_codesign_verify() {
    local binary="$1"
    shift
    if command -v codesign >/dev/null 2>&1; then
        codesign --verify --strict --all-architectures "$@" "$binary"
        return
    fi
    ldid -h "$binary" >/dev/null
}

sparkle_codesign_remove() {
    local binary="$1"
    if command -v codesign >/dev/null 2>&1; then
        codesign --remove-signature "$binary"
        return
    fi
    ldid -r "$binary"
}

# FFmpeg ships its libraries under names Instagram also uses for its own
# vendored copies (libavutil, libavcodec). Anything installed into the app's
# Frameworks directory would replace those and break Instagram's strong links,
# so every framework is renamed into Sparkle's own namespace before staging.
# The renamed set is identical in every package; only its destination differs.
original_names=(libavutil libswresample libswscale libavcodec libavformat libavfilter libavdevice ffmpegkit)
renamed_names=(spk.avutil spk.swresample spk.swscale spk.avcodec spk.avformat spk.avfilter spk.avdevice spk.ffmpegkit)

case "$MODE" in
    ""|--localizations-only|--augment-ffmpeg|--frameworks-only) ;;
    *)
        echo "Unknown mode: $MODE" >&2
        echo "Usage: stage-sparkle-bundle.sh <destination> [--localizations-only|--augment-ffmpeg|--frameworks-only]" >&2
        exit 1
        ;;
esac

if [ "$MODE" != "--frameworks-only" ] && [ "$(basename "$DESTINATION")" != "Sparkle.bundle" ]; then
    echo "Refusing to replace a destination not named Sparkle.bundle: $DESTINATION" >&2
    exit 1
fi

normalize_permissions() {
    # Contributed catalogs can arrive with owner-only permissions. Jailbreak
    # packages install resources as root:wheel, while Instagram reads them as
    # mobile, so every bundled resource must remain world-readable. Preserve
    # executable bits on framework binaries while removing unintended writes.
    find "$1" -type d -exec chmod 755 {} +
    find "$1" -type f -exec chmod a+r,u+w,go-w {} +
}

# Copies the FFmpeg frameworks into $1 under Sparkle's names, rewriting the
# install names so each one resolves its siblings through @loader_path. The
# frameworks stay siblings in every layout, so that one rewrite is correct for
# the resource bundle and for the app's Frameworks directory alike.
stage_ffmpeg_frameworks() {
    local destination="$1"
    local signing="$2"
    local index original renamed source_framework source_binary destination_framework destination_binary identifier
    local targets=()

    mkdir -p "$destination"
    for index in "${!original_names[@]}"; do
        rm -rf "$destination/${original_names[$index]}.framework" "$destination/${renamed_names[$index]}.framework"
    done
    rm -rf "$destination/FFmpegKit" "$destination/FFmpegKit.bundle"

    for index in "${!original_names[@]}"; do
        original="${original_names[$index]}"
        renamed="${renamed_names[$index]}"
        source_framework="$ROOT_DIR/modules/ffmpegkit/${original}.framework"
        source_binary="$source_framework/$original"
        destination_framework="$destination/${renamed}.framework"
        destination_binary="$destination_framework/$renamed"
        identifier="com.sparkle.ffmpeg.${renamed#spk.}"

        if [ ! -f "$source_binary" ]; then
            echo "Missing FFmpeg binary: $source_binary" >&2
            echo "Run ./fetch-ffmpegkit.sh first." >&2
            exit 1
        fi

        cp -R "$source_framework" "$destination_framework"
        # Headers, module maps and upstream's Xcode build-phase helper are for
        # apps that link the framework at build time; the package only needs the
        # binary and the licence texts.
        rm -rf "$destination_framework/Headers" "$destination_framework/Modules" \
            "$destination_framework/_CodeSignature" "$destination_framework/strip-frameworks.sh"
        mv "$destination_framework/$original" "$destination_binary"

        # Signers locate a framework's code through CFBundleExecutable, and
        # Cyan derives the binary name from the directory name, so both have to
        # follow the rename.
        plistbuddy -c "Set :CFBundleExecutable $renamed" "$destination_framework/Info.plist"
        plistbuddy -c "Set :CFBundleIdentifier $identifier" "$destination_framework/Info.plist"
        plistbuddy -c "Set :CFBundleName $renamed" "$destination_framework/Info.plist"

        install_name_tool -id "@loader_path/../${renamed}.framework/${renamed}" "$destination_binary"
        targets+=("$destination_binary")
    done

    local binary dependency_original dependency_renamed
    for binary in "${targets[@]}"; do
        for index in "${!original_names[@]}"; do
            dependency_original="${original_names[$index]}"
            dependency_renamed="${renamed_names[$index]}"
            install_name_tool -change \
                "@rpath/${dependency_original}.framework/${dependency_original}" \
                "@loader_path/../${dependency_renamed}.framework/${dependency_renamed}" \
                "$binary" 2>/dev/null || true
        done

        if otool -L "$binary" | grep -Eq '@rpath/(ffmpegkit|libav|libsw)'; then
            echo "Unresolved FFmpeg dependency in $binary" >&2
            otool -L "$binary" >&2
            exit 1
        fi
    done

    case "$signing" in
        code-only)
            # Theos normalizes framework metadata after after-stage, so a
            # signature sealing the Info.plist would already be invalid by the
            # time the deb is assembled. Sign outside the framework directory so
            # the signature covers code alone.
            local signing_directory signing_binary
            signing_directory="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-ffmpeg-signing.XXXXXX")"
            for binary in "${targets[@]}"; do
                signing_binary="$signing_directory/$(basename "$binary")"
                cp "$binary" "$signing_binary"
                sparkle_codesign_sign "$signing_binary" \
                    "com.sparkle.ffmpeg.$(basename "$binary" | sed 's/^spk\.//')"
                cp "$signing_binary" "$binary"
                sparkle_codesign_verify "$binary" --ignore-resources
            done
            rm -rf "$signing_directory"
            ;;
        sealed)
            for binary in "${targets[@]}"; do
                sparkle_codesign_sign "$binary"
                sparkle_codesign_verify "$binary"
            done
            ;;
        none)
            # Sideload packaging hands these to the user's signer, which
            # replaces the signature outright. An ad-hoc one buys nothing and is
            # rejected outright once the app is signed with a real certificate.
            for binary in "${targets[@]}"; do
                if otool -l "$binary" | grep -q LC_CODE_SIGNATURE; then
                    sparkle_codesign_remove "$binary"
                fi
            done
            ;;
    esac

    local framework_count
    framework_count="$(find "$destination" -mindepth 1 -maxdepth 1 -type d -name 'spk.*.framework' | wc -l | tr -d ' ')"
    if [ "$framework_count" != 8 ]; then
        echo "Expected eight Sparkle FFmpeg frameworks in $destination; found $framework_count" >&2
        exit 1
    fi
}

case "$MODE" in
    --frameworks-only)
        stage_ffmpeg_frameworks "$DESTINATION" none
        ;;
    --augment-ffmpeg)
        if [ ! -f "$DESTINATION/Info.plist" ]; then
            echo "Sparkle.bundle was not staged before FFmpeg augmentation: $DESTINATION" >&2
            exit 1
        fi
        stage_ffmpeg_frameworks "$DESTINATION" code-only
        ;;
    *)
        rm -rf "$DESTINATION"
        mkdir -p "$DESTINATION"
        cp "$ROOT_DIR/resources/Sparkle.bundle/Info.plist" "$DESTINATION/Info.plist"
        for localization in "$ROOT_DIR"/resources/Sparkle.bundle/*.lproj; do
            cp -R "$localization" "$DESTINATION/"
        done
        if [ "$MODE" != "--localizations-only" ]; then
            stage_ffmpeg_frameworks "$DESTINATION" sealed
        fi
        ;;
esac

normalize_permissions "$DESTINATION"

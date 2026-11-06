#!/usr/bin/env bash

set -e

CMAKE_OSX_ARCHITECTURES="arm64e;arm64"
CMAKE_OSX_SYSROOT="iphoneos"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Sparkle version, read from the control file (single source of truth).
SPARKLE_VERSION="$(awk '/^Version:/ {print $2; exit}' "$ROOT_DIR/control")"

# macOS ships PlistBuddy; Linux-hosted IPA packaging uses tools/plistbuddy.py.
plistbuddy() {
    if [ -x /usr/libexec/PlistBuddy ]; then
        /usr/libexec/PlistBuddy "$@"
    else
        python3 "$ROOT_DIR/tools/plistbuddy.py" "$@"
    fi
}

FFMPEG_MODULES_DIR="$ROOT_DIR/modules/ffmpegkit"
FFMPEG_FRAMEWORKS=(
    "$FFMPEG_MODULES_DIR/ffmpegkit.framework"
    "$FFMPEG_MODULES_DIR/libavcodec.framework"
    "$FFMPEG_MODULES_DIR/libavdevice.framework"
    "$FFMPEG_MODULES_DIR/libavfilter.framework"
    "$FFMPEG_MODULES_DIR/libavformat.framework"
    "$FFMPEG_MODULES_DIR/libavutil.framework"
    "$FFMPEG_MODULES_DIR/libswresample.framework"
    "$FFMPEG_MODULES_DIR/libswscale.framework"
)

ensure_ffmpeg_frameworks() {
    for framework in "${FFMPEG_FRAMEWORKS[@]}"; do
        if [ ! -d "$framework" ]; then
            echo -e "\033[1m\033[0;31mMissing FFmpeg framework: $framework\033[0m"
            echo "Run ./fetch-ffmpegkit.sh first."
            exit 1
        fi
    done
}

stage_sparkle_resource_bundle() {
    local destination="$1"
    local mode="${2:-}"
    if [ -n "$mode" ]; then
        "$ROOT_DIR/tools/stage-sparkle-bundle.sh" "$destination" "$mode"
    else
        "$ROOT_DIR/tools/stage-sparkle-bundle.sh" "$destination"
    fi
}

newest_sparkle_deb() {
    local newest
    newest="$(ls -t "$ROOT_DIR/packages/"com.sparkle.sparkle_*.deb 2>/dev/null | head -n 1)"
    if [ -z "$newest" ]; then
        return 1
    fi
    echo "$newest"
}



ensure_flexing_submodule() {
    if [ -z "$(ls -A modules/FLEXing 2>/dev/null)" ]; then
        echo -e '\033[1m\033[0;31mFLEXing submodule not found.\nPlease run the following command to checkout submodules:\n\n\033[0m    git submodule update --init --recursive'
        exit 1
    fi
}

build_flex_library() {
    echo -e '\033[1m\033[32mBuilding libFLEX.dylib...\033[0m'
    make -C "$ROOT_DIR/modules/FLEXing/libflex" clean
    # Linux Theos has no arm64e runtime; keep the slice Sparkle ships.
    make -C "$ROOT_DIR/modules/FLEXing/libflex" \
        DEBUG=0 FINALPACKAGE=1 \
        ARCHS=arm64 \
        TARGET=iphone:clang:16.2:15.0
}

build_sideload_fix_library() {
    echo -e '\033[1m\033[32mBuilding SPKSideloadFix.dylib...\033[0m'
    make -C "$ROOT_DIR/modules/SPKSideloadFix" DEBUG=0 FINALPACKAGE=1
}

theos_dylib_path() {
    local name
    local path
    for name in "$@"; do
        for path in \
            ".theos/obj/${name}.dylib" \
            ".theos/obj/debug/${name}.dylib" \
            "modules/FLEXing/libflex/.theos/obj/${name}.dylib" \
            "modules/FLEXing/libflex/.theos/obj/debug/${name}.dylib"; do
            if [ -f "$path" ]; then
                echo "$path"
                return 0
            fi
        done
    done
    return 1
}

select_input_ipa() {
    local ipa_files=("$@")
    local selected_index

    if [ ${#ipa_files[@]} -eq 1 ]; then
        basename "${ipa_files[0]}"
        return 0
    fi

    if [ -t 0 ] && [ -z "${CI:-}" ]; then
        echo -e '\033[1m\033[0;33mMultiple IPA files found in packages directory. Choose one to build:\033[0m' >&2
        local i=1
        for ipa_path in "${ipa_files[@]}"; do
            echo "  [$i] $(basename "$ipa_path")" >&2
            i=$((i + 1))
        done

        while true; do
            printf 'Selection [1-%d]: ' "${#ipa_files[@]}" >&2
            read -r selected_index
            if [[ "$selected_index" =~ ^[0-9]+$ ]] && [ "$selected_index" -ge 1 ] && [ "$selected_index" -le "${#ipa_files[@]}" ]; then
                basename "${ipa_files[$((selected_index - 1))]}"
                return 0
            fi
            echo -e '\033[1m\033[0;31mInvalid selection.\033[0m' >&2
        done
    fi

    echo -e '\033[1m\033[0;33mMultiple IPA files found in packages directory. Non-interactive environment detected; using the latest one:\033[0m' >&2
    for ipa_path in "${ipa_files[@]}"; do
        echo "  - $(basename "$ipa_path")" >&2
    done
    echo >&2
    basename "${ipa_files[${#ipa_files[@]}-1]}"
}

sideload_fix_dylib_path() {
    local path
    for path in \
        "$ROOT_DIR/modules/SPKSideloadFix/.theos/obj/SPKSideloadFix.dylib" \
        "$ROOT_DIR/modules/SPKSideloadFix/.theos/obj/debug/SPKSideloadFix.dylib"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

copy_flex_library_into_ipa() {
    local input_ipa="$1"
    local output_ipa="$2"
    local libflex_path="$3"
    local temp_dir
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-flex-ipa.XXXXXX")"

    unzip -q "$input_ipa" -d "$temp_dir"

    local app_dir
    app_dir="$(find "$temp_dir/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
    if [ -z "$app_dir" ]; then
        echo -e '\033[1m\033[0;31mCould not find Payload/*.app in IPA.\033[0m'
        rm -rf "$temp_dir"
        exit 1
    fi

    mkdir -p "$app_dir/Frameworks"
    if command -v ditto >/dev/null 2>&1; then
        ditto "$libflex_path" "$app_dir/Frameworks/libFLEX.dylib"
    else
        cp -a "$libflex_path" "$app_dir/Frameworks/libFLEX.dylib"
    fi

    rm -f "$output_ipa"
    (
        cd "$temp_dir"
        zip -qry "$output_ipa" Payload
    )
    rm -rf "$temp_dir"
}

# Cyan copies an injected .deb twice: the resource bundle lands in the app root
# with its contents intact, and every framework inside it is also hoisted into
# Frameworks/. Only the hoisted copies sit where a sideload signer will re-sign
# them, so the ones left in the bundle are dead weight that the loader must
# never reach for.
prune_bundled_ffmpeg_frameworks_from_ipa() {
    local input_ipa="$1"
    local output_ipa="$2"
    local temp_dir
    local app_dir
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-ffmpeg-prune.XXXXXX")"

    unzip -q "$input_ipa" -d "$temp_dir"
    app_dir="$(find "$temp_dir/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
    if [ -z "$app_dir" ]; then
        echo -e '\033[1m\033[0;31mCould not find Payload/*.app in IPA.\033[0m'
        rm -rf "$temp_dir"
        exit 1
    fi

    find "$app_dir/Sparkle.bundle" -mindepth 1 -maxdepth 1 -type d -name 'spk.*.framework' -exec rm -rf {} + 2>/dev/null || true

    rm -f "$output_ipa"
    (
        cd "$temp_dir"
        zip -qry "$output_ipa" Payload
    )
    rm -rf "$temp_dir"
}

strip_appex_bundles() {
    local input_ipa="$1"
    local output_ipa="$2"
    local temp_dir
    local app_dir
    local appex_count
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-strip-appex.XXXXXX")"

    unzip -q "$input_ipa" -d "$temp_dir"

    app_dir="$(find "$temp_dir/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
    if [ -z "$app_dir" ]; then
        echo -e '\033[1m\033[0;31mCould not find Payload/*.app in IPA.\033[0m'
        rm -rf "$temp_dir"
        exit 1
    fi

    appex_count="$(find "$app_dir" -type d -name "*.appex" | wc -l | tr -d ' ')"
    find "$app_dir" -type d -name "*.appex" -prune -exec rm -rf {} +
    echo -e "\033[1m\033[0;33mStripped ${appex_count} app extension bundle(s).\033[0m"

    rm -f "$output_ipa"
    (
        cd "$temp_dir"
        zip -qry "$output_ipa" Payload
    )
    rm -rf "$temp_dir"
}

# The URL scheme only this install answers. Every Instagram copy registers the
# stock schemes, so the share and Safari extensions reach the app through this
# one instead (modules/SPKSideloadFix/src/AppHandoff.xm maps it back). A custom
# bundle ID gets its own scheme so two Sparkle builds can sit side by side.
sparkle_private_url_scheme() {
    local scheme="sparkle-ig"
    if [ -n "${OPT_BUNDLE_ID:-}" ]; then
        scheme="${scheme}-$(printf '%s' "$OPT_BUNDLE_ID" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
    fi
    echo "$scheme"
}

# Args: app dir, scheme. Adds the scheme to the app's first URL type.
register_private_url_scheme() {
    local plist="$1/Info.plist"
    local scheme="$2"

    if plistbuddy -c "Print :CFBundleURLTypes" "$plist" 2>/dev/null | grep -qx "[[:space:]]*${scheme}"; then
        return 0
    fi
    if ! plistbuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes" "$plist" >/dev/null 2>&1; then
        plistbuddy -c "Add :CFBundleURLTypes array" "$plist" 2>/dev/null || true
        plistbuddy -c "Add :CFBundleURLTypes:0 dict" "$plist"
        plistbuddy -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor" "$plist"
        plistbuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist"
    fi
    plistbuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes: string ${scheme}" "$plist"
}

# Args: appex dir. Compiles the Safari extension's native half into it. The
# bundle is otherwise plain files, but iOS only loads an extension that has an
# executable with the principal class its Info.plist names.
build_safari_extension_handler() {
    local appex_dir="$1"
    local source="$ROOT_DIR/modules/SafariExtensionHandler/SPKSafariExtensionHandler.m"
    local theos_dir="${THEOS:-$HOME/theos}"
    local sdk="$theos_dir/sdks/iPhoneOS16.2.sdk"
    local executable

    [ -d "$sdk" ] || sdk="$(find "$theos_dir/sdks" -maxdepth 1 -name 'iPhoneOS*.sdk' 2>/dev/null | sort | head -n 1)"
    if [ -z "$sdk" ] || [ ! -d "$sdk" ]; then
        echo -e "\033[1m\033[0;31mNo iPhoneOS SDK found in ${theos_dir}/sdks for the Safari extension.\033[0m"
        return 1
    fi

    executable="$(plistbuddy -c "Print :CFBundleExecutable" "$appex_dir/Info.plist")" || return 1
    # NSExtensionMain is the entry point of every app extension; there is no main().
    # Built and signed outside the bundle: signing it in place would seal the
    # whole extension before its scripts are final.
    local build_dir
    local -a cc signer
    build_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-safari-handler.XXXXXX")"
    if command -v xcrun >/dev/null 2>&1; then
        cc=(xcrun clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0)
    else
        local theos_clang="$theos_dir/toolchain/linux/iphone/bin/clang"
        if [ ! -x "$theos_clang" ]; then
            echo -e "\033[1m\033[0;31mNo clang for the Safari extension (xcrun or ${theos_clang}).\033[0m"
            rm -rf "$build_dir"
            return 1
        fi
        cc=("$theos_clang" -target arm64-apple-ios15.0 -isysroot "$sdk" -miphoneos-version-min=15.0)
    fi
    if command -v codesign >/dev/null 2>&1; then
        signer=(codesign --force --sign -)
    elif command -v ldid >/dev/null 2>&1; then
        signer=(ldid -S)
    else
        echo -e '\033[1m\033[0;31mNo codesign or ldid to sign the Safari extension.\033[0m'
        rm -rf "$build_dir"
        return 1
    fi
    if "${cc[@]}" -fobjc-arc -fapplication-extension -Os -e _NSExtensionMain -framework Foundation \
        -o "$build_dir/$executable" "$source" &&
        "${signer[@]}" "$build_dir/$executable" >/dev/null 2>&1 &&
        mv "$build_dir/$executable" "$appex_dir/$executable"; then
        rm -rf "$build_dir"
        return 0
    fi
    rm -rf "$build_dir"
    return 1
}

embed_safari_extension() {
    local input_ipa="$1"
    local output_ipa="$2"
    local scheme
    scheme="$(sparkle_private_url_scheme)"
    local appex_src="$ROOT_DIR/modules/OpenInSparkleSafariExtension.appex"
    local temp_dir
    local app_dir

    [ -d "$appex_src" ] || {
        echo -e "\033[1m\033[0;31mSafari extension source not found at ${appex_src}\033[0m"
        return 1
    }

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-embed-safari.XXXXXX")"

    unzip -q "$input_ipa" -d "$temp_dir"

    app_dir="$(find "$temp_dir/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
    if [ -z "$app_dir" ]; then
        echo -e '\033[1m\033[0;31mCould not find Payload/*.app in IPA.\033[0m'
        rm -rf "$temp_dir"
        exit 1
    fi

    mkdir -p "$app_dir/PlugIns"
    rm -rf "$app_dir/PlugIns/OpenInSparkleSafariExtension.appex"
    cp -R "$appex_src" "$app_dir/PlugIns/"
    build_safari_extension_handler "$app_dir/PlugIns/OpenInSparkleSafariExtension.appex" || {
        echo -e '\033[1m\033[0;31mCould not build the Safari extension executable.\033[0m'
        rm -rf "$temp_dir"
        exit 1
    }

    register_private_url_scheme "$app_dir" "$scheme"
    if [ "$scheme" != "sparkle-ig" ]; then
        sed -i '' "s|var APP_SCHEME = \"sparkle-ig\";|var APP_SCHEME = \"${scheme}\";|" \
            "$app_dir/PlugIns/OpenInSparkleSafariExtension.appex/content.js"
        grep -q "var APP_SCHEME = \"${scheme}\";" "$app_dir/PlugIns/OpenInSparkleSafariExtension.appex/content.js" || {
            echo -e '\033[1m\033[0;31mCould not set the URL scheme in the Safari extension.\033[0m'
            rm -rf "$temp_dir"
            exit 1
        }
    fi
    echo -e "\033[1m\033[32mRegistered URL scheme ${scheme}://\033[0m"
    if [ "${OPT_PATCH:-0}" -eq 0 ]; then
        echo -e '\033[1m\033[0;33mWithout --patch nothing answers that scheme, so the Safari extension will not open the app.\033[0m'
    fi

    rm -f "$output_ipa"
    (
        cd "$temp_dir"
        zip -qry "$output_ipa" Payload
    )
    rm -rf "$temp_dir"
}

inject_custom_icons() {
    local input_ipa="$1"
    local output_ipa="$2"
    local temp_dir
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-icons-ipa.XXXXXX")"

    unzip -q "$input_ipa" -d "$temp_dir"

    local app_dir
    app_dir="$(find "$temp_dir/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
    if [ -z "$app_dir" ]; then
        echo -e '\033[1m\033[0;31mCould not find Payload/*.app in IPA.\033[0m'
        rm -rf "$temp_dir"
        exit 1
    fi

    echo -e '\033[1m\033[32mInjecting Sparkle app icons...\033[0m'

    # Icon Composer packages, spliced into Instagram's own Assets.car.
    # That compiler ships with Xcode 26. A Linux sideload build keeps Instagram's icon.
    if command -v xcode-select >/dev/null 2>&1 || [ -x "/Applications/Icon Composer.app/Contents/Executables/ictool" ]; then
        "$ROOT_DIR/tools/splice-glass-icons.sh" "$app_dir"
    else
        echo -e '\033[1m\033[0;33mIcon Composer is not available here, so this IPA keeps Instagram'\''s icon.\033[0m'
    fi

    rm -f "$output_ipa"
    (
        cd "$temp_dir"
        zip -qry "$output_ipa" Payload
    )
    rm -rf "$temp_dir"
}

# Rename the freshly built .deb to Sparkle_v<version>_<rootless|rootful>.deb.
# Arg: scheme name (rootless|rootful). Echoes the final path.
rename_sparkle_deb() {
    local scheme="$1"
    local newest dest
    newest="$(ls -t "$ROOT_DIR/packages/"com.sparkle.sparkle_*.deb 2>/dev/null | head -n 1)"
    if [ -z "$newest" ]; then
        echo -e '\033[1m\033[0;31mCould not find a built .deb to rename.\033[0m' >&2
        return 1
    fi
    dest="$ROOT_DIR/packages/Sparkle_v${SPARKLE_VERSION}_${scheme}.deb"
    mv -f "$newest" "$dest"
    echo "$dest"
}

# Read the Instagram marketing version (CFBundleShortVersionString) from an IPA.
# Falls back to a filename-derived guess, then to "unknown".
ig_app_version() {
    local ipa="$1"
    local tmp plist version
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-igver.XXXXXX")"

    if unzip -o -q "$ipa" "Payload/*.app/Info.plist" -d "$tmp" >/dev/null 2>&1; then
        plist="$(find "$tmp/Payload" -maxdepth 2 -name Info.plist 2>/dev/null | head -n 1)"
        if [ -n "$plist" ]; then
            version="$(plistbuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
        fi
    fi
    rm -rf "$tmp"

    if [ -z "$version" ]; then
        # e.g. com.burbn.instagram_437.1.0.decrypted.ipa -> 437.1.0
        version="$(basename "$ipa" | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')"
    fi
    [ -z "$version" ] && version="unknown"
    echo "$version"
}

# Build the "<flags>" segment of the output name from the OPT_* globals.
# Empty for a plain release build (--inject --patch, no extras).
sparkle_flag_token() {
    local parts=()
    if [ "${OPT_INJECT:-0}" -eq 1 ] && [ "${OPT_PATCH:-0}" -eq 1 ]; then
        # Canonical full release build (flex included): only annotate the
        # notable deviations from it.
        [ "${OPT_DEV:-0}" -eq 1 ] && parts+=(dev)
        [ "${OPT_NO_FFMPEG:-0}" -eq 1 ] && parts+=(no-ffmpeg)
        [ "${OPT_FLEX:-0}" -eq 0 ] && parts+=(no-flex)
        [ "${OPT_STRIP_EXTENSIONS:-0}" -eq 1 ] && parts+=(no-ext)
    else
        # Partial / à la carte build: spell out every included component.
        [ "${OPT_INJECT:-0}" -eq 1 ] && parts+=(inject)
        [ "${OPT_BUNDLE:-0}" -eq 1 ] && parts+=(bundle)
        [ "${OPT_FLEX:-0}" -eq 1 ] && parts+=(flex)
        [ "${OPT_PATCH:-0}" -eq 1 ] && parts+=(patch)
        [ "${OPT_STRIP_EXTENSIONS:-0}" -eq 1 ] && parts+=(no-ext)
        [ "${OPT_DEV:-0}" -eq 1 ] && parts+=(dev)
    fi
    local IFS=_
    echo "${parts[*]}"
}

# Compose the output IPA name:
#   Sparkle[_<flags>]_v<sparkle version>_IG_v<instagram version>.ipa
# Globals: SPARKLE_VERSION, IG_VERSION, OPT_*
sparkle_sideload_output_ipa() {
    local flags name
    flags="$(sparkle_flag_token)"
    name="Sparkle"
    [ -n "$flags" ] && name="${name}_${flags}"
    name="${name}_v${SPARKLE_VERSION}"
    [ -n "${IG_VERSION:-}" ] && name="${name}_IG_v${IG_VERSION}"
    echo "${name}.ipa"
}

# Building modes
if [ "$1" == "ipa" ];
then
    shift
    OPT_INJECT=0
    OPT_BUNDLE=0
    OPT_NO_FFMPEG=0
    OPT_FLEX=0
    OPT_PATCH=0
    OPT_STRIP_EXTENSIONS=0
    OPT_DEV=0
    OPT_BUILDONLY=0
    OPT_BUNDLE_ID=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --release)
                OPT_INJECT=1
                OPT_PATCH=1
                ;;
            --inject) OPT_INJECT=1 ;;
            --bundle) OPT_BUNDLE=1 ;;
            --no-ffmpeg) OPT_NO_FFMPEG=1 ;;
            --flex) OPT_FLEX=1 ;;
            --patch) OPT_PATCH=1 ;;
            --no-ext) OPT_STRIP_EXTENSIONS=1 ;;
            --dev) OPT_DEV=1 ;;
            --buildonly) OPT_BUILDONLY=1 ;;
            --bundle-id)
                OPT_BUNDLE_ID="$2"
                shift
                ;;
            *)
                echo -e "\033[1m\033[0;31mUnknown ipa flag: $1\033[0m"
                echo "Use: ./build.sh ipa [--release|--inject|--bundle|--no-ffmpeg|--flex|--patch|--no-ext|--dev|--buildonly|--bundle-id <id>] ..."
                exit 1
                ;;
        esac
        shift
    done

    if [ "$OPT_INJECT" -eq 0 ] && [ "$OPT_BUNDLE" -eq 0 ] && [ "$OPT_FLEX" -eq 0 ] && [ "$OPT_STRIP_EXTENSIONS" -eq 0 ]; then
        echo -e '\033[1m\033[0;31msideload: specify at least one of --release, --inject, --bundle, --flex, --no-ext\033[0m'
        exit 1
    fi

    MAKEARGS='DEBUG=0 FINALPACKAGE=1'
    COMPRESSION=9
    if [ "$OPT_DEV" -eq 1 ]; then
        MAKEARGS='DEV=1'
        COMPRESSION=0
    fi

    if [ "$OPT_FLEX" -eq 1 ]; then
        ensure_flexing_submodule
    fi

    if [ "$OPT_INJECT" -eq 1 ]; then
        if [ "$OPT_DEV" -eq 0 ]; then
            rm -rf "packages/cache"
        fi
        make clean
        rm -rf .theos
    fi

    if [ "$OPT_BUILDONLY" -eq 0 ]; then
        candidateIpaFiles=($(ls packages/com.burbn.instagram*.ipa 2>/dev/null | sort -V))
        if [ ${#candidateIpaFiles[@]} -eq 0 ]; then
            echo -e '\033[1m\033[0;31m./packages/com.burbn.instagram.ipa not found.\nPlease put a decrypted Instagram IPA in its path.\033[0m'
            exit 1
        fi
        ipaFiles=()
        for candidateIpa in "${candidateIpaFiles[@]}"; do
            case "$(basename "$candidateIpa")" in
                *-dev*.ipa|*-inject*.ipa|*-ffmpeg*.ipa|*-bundle*.ipa|*-flex*.ipa|*-patch*.ipa|*-sidestore*.ipa|*-no-ext*.ipa)
                    ;;
                *)
                    ipaFiles+=("$candidateIpa")
                    ;;
            esac
        done
        if [ ${#ipaFiles[@]} -eq 0 ]; then
            ipaFiles=("${candidateIpaFiles[@]}")
        fi

        ipaFile="$(select_input_ipa "${ipaFiles[@]}")"
    fi

    echo -e '\033[1m\033[32mSideload build...\033[0m'
    if [ "$OPT_INJECT" -eq 1 ]; then
        if [ "$OPT_NO_FFMPEG" -eq 1 ]; then
            make package THEOS_PACKAGE_SCHEME=rootless SPARKLE_NO_FFMPEG=1 $MAKEARGS
        else
            ensure_ffmpeg_frameworks
            make package THEOS_PACKAGE_SCHEME=rootless $MAKEARGS
        fi
    fi
    if [ "$OPT_FLEX" -eq 1 ]; then
        build_flex_library
    fi
    if [ "$OPT_PATCH" -eq 1 ]; then
        build_sideload_fix_library
    fi

    if [ "$OPT_BUILDONLY" -eq 1 ]; then
        echo -e '\033[1m\033[32mBuild-only mode: skipping IPA.\033[0m'
        exit 0
    fi

    SPARKLE_DEB=""
    SPARKLE_BUNDLE_STAGE_ROOT=""
    SPARKLE_BUNDLE_PATH=""
    BUNDLE_FFMPEG_PATH=""
    LIBFLEXPATH=""
    SIDELOADFIXPATH=""
    if [ "$OPT_INJECT" -eq 1 ]; then
        SPARKLE_DEB="$(newest_sparkle_deb)" || {
            echo -e '\033[1m\033[0;31mCould not find the built Sparkle deb.\033[0m'
            exit 1
        }
    fi
    if [ "$OPT_FLEX" -eq 1 ]; then
        LIBFLEXPATH="$(theos_dylib_path libFLEX libflex)" || {
            echo -e '\033[1m\033[0;31mCould not find built libFLEX.dylib.\033[0m'
            exit 1
        }
    fi
    if [ "$OPT_PATCH" -eq 1 ]; then
        SIDELOADFIXPATH="$(sideload_fix_dylib_path)" || {
            echo -e '\033[1m\033[0;31mCould not find built SPKSideloadFix.dylib.\033[0m'
            exit 1
        }
    fi
    # Injecting Sparkle hands Cyan the deb, which already carries the dylib, the
    # resource bundle and the FFmpeg frameworks. So --bundle only does anything
    # on its own: resources without the tweak. Cyan globs a deb for nested
    # frameworks but never a plain directory, so that path stages and passes
    # each framework itself, otherwise they would land somewhere no sideload
    # signer reaches and fail to load.
    if [ "$OPT_INJECT" -eq 0 ] && [ "$OPT_BUNDLE" -eq 1 ]; then
        SPARKLE_BUNDLE_STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-cyan-bundle.XXXXXX")"
        SPARKLE_BUNDLE_PATH="$SPARKLE_BUNDLE_STAGE_ROOT/Sparkle.bundle"
        echo -e '\033[1m\033[32mBuilding Sparkle.bundle for Cyan (localizations only)...\033[0m'
        stage_sparkle_resource_bundle "$SPARKLE_BUNDLE_PATH" --localizations-only
        if [ "$OPT_NO_FFMPEG" -eq 0 ]; then
            ensure_ffmpeg_frameworks
            echo -e '\033[1m\033[32mStaging FFmpeg frameworks for Cyan...\033[0m'
            BUNDLE_FFMPEG_PATH="$SPARKLE_BUNDLE_STAGE_ROOT/Frameworks"
            stage_sparkle_resource_bundle "$BUNDLE_FFMPEG_PATH" --frameworks-only
        fi
    fi

    IG_VERSION="$(ig_app_version "packages/${ipaFile}")"
    OUTPUT_IPA="$(sparkle_sideload_output_ipa)"
    ipa_out="$ROOT_DIR/packages/${OUTPUT_IPA}"
    ipa_stage_input="$ROOT_DIR/packages/.sparkle-build-stage-input.ipa"
    ipa_flex_tmp="$ROOT_DIR/packages/.sparkle-build-tmp-flex.ipa"
    ipa_strip_tmp="$ROOT_DIR/packages/.sparkle-build-tmp-strip.ipa"
    ipa_icons_tmp="$ROOT_DIR/packages/.sparkle-build-tmp-icons.ipa"
    ipa_ffmpeg_tmp="$ROOT_DIR/packages/.sparkle-build-tmp-ffmpeg.ipa"
    rm -f "$ipa_out" "$ipa_stage_input" "$ipa_flex_tmp" "$ipa_strip_tmp" "$ipa_icons_tmp" "$ipa_ffmpeg_tmp"

    cp "packages/${ipaFile}" "$ipa_stage_input"

    if [ "$OPT_FLEX" -eq 1 ]; then
        echo -e '\033[1m\033[32mInjecting libFLEX.dylib...\033[0m'
        copy_flex_library_into_ipa "$ipa_stage_input" "$ipa_flex_tmp" "$LIBFLEXPATH"
        mv -f "$ipa_flex_tmp" "$ipa_stage_input"
    fi

    if [ "$OPT_STRIP_EXTENSIONS" -eq 1 ]; then
        echo -e '\033[1m\033[32mStripping app extensions...\033[0m'
        strip_appex_bundles "$ipa_stage_input" "$ipa_strip_tmp"
        mv -f "$ipa_strip_tmp" "$ipa_stage_input"
    else
        echo -e '\033[1m\033[32mEmbedding Safari extension and registering the app URL scheme...\033[0m'
        ipa_embed_tmp="$ROOT_DIR/packages/.sparkle-build-tmp-embed.ipa"
        embed_safari_extension "$ipa_stage_input" "$ipa_embed_tmp"
        mv -f "$ipa_embed_tmp" "$ipa_stage_input"
    fi

    # Inject Sparkle alternate icons
    inject_custom_icons "$ipa_stage_input" "$ipa_icons_tmp"
    mv -f "$ipa_icons_tmp" "$ipa_stage_input"

    echo -e '\033[1m\033[32mCreating the IPA file...\033[0m'
    CYAN_FILES=()
    if [ "$OPT_INJECT" -eq 1 ]; then
        CYAN_FILES+=("$SPARKLE_DEB")
    fi
    if [ -n "$SPARKLE_BUNDLE_PATH" ]; then
        CYAN_FILES+=("$SPARKLE_BUNDLE_PATH")
    fi
    if [ -n "$BUNDLE_FFMPEG_PATH" ]; then
        for staged_framework in "$BUNDLE_FFMPEG_PATH"/spk.*.framework; do
            CYAN_FILES+=("$staged_framework")
        done
    fi
    if [ "$OPT_PATCH" -eq 1 ] && [ "$OPT_STRIP_EXTENSIONS" -eq 1 ]; then
        CYAN_FILES+=("$SIDELOADFIXPATH")
    fi

    if [ "${#CYAN_FILES[@]}" -gt 0 ]; then
        if [ -n "$OPT_BUNDLE_ID" ]; then
            cyan -i "$ipa_stage_input" -o "$ipa_out" -f "${CYAN_FILES[@]}" -c "$COMPRESSION" -m 15.0 -du -b "$OPT_BUNDLE_ID"
        else
            cyan -i "$ipa_stage_input" -o "$ipa_out" -f "${CYAN_FILES[@]}" -c "$COMPRESSION" -m 15.0 -du
        fi
    else
        cp "$ipa_stage_input" "$ipa_out"
    fi

    if [ "$OPT_INJECT" -eq 1 ] && [ "$OPT_NO_FFMPEG" -eq 0 ]; then
        echo -e '\033[1m\033[32mPruning duplicate FFmpeg frameworks...\033[0m'
        prune_bundled_ffmpeg_frameworks_from_ipa "$ipa_out" "$ipa_ffmpeg_tmp"
        mv -f "$ipa_ffmpeg_tmp" "$ipa_out"
    fi

    rm -f "$ipa_stage_input"
    if [ -n "$SPARKLE_BUNDLE_STAGE_ROOT" ]; then
        rm -rf "$SPARKLE_BUNDLE_STAGE_ROOT"
    fi

    if [ "$OPT_PATCH" -eq 1 ] && [ "$OPT_STRIP_EXTENSIONS" -eq 0 ]; then
        echo -e '\033[1m\033[32mPatching IPA for sideloading...\033[0m'
        ipapatch --input "$ipa_out" --inplace --noconfirm --dylib "$SIDELOADFIXPATH"
    elif [ "$OPT_PATCH" -eq 1 ]; then
        echo -e '\033[1m\033[32mSkipping ipapatch\033[0m'
    fi

    echo -e "\033[1m\033[32mDone, we hope you enjoy Sparkle!\033[0m\n\nOutput IPA: $ipa_out"

elif [ "$1" == "rootless" ];
then
    
    # Clean build artifacts
    make clean
    rm -rf .theos

    echo -e '\033[1m\033[32mBuilding Sparkle tweak for rootless\033[0m'

    # Passed on the command line, not exported: ~/.config/theos/rc.mk assigns
    # THEOS_PACKAGE_SCHEME as a makefile variable, which overrides the
    # environment. Only a command-line assignment beats it.
    ensure_ffmpeg_frameworks
    make package THEOS_PACKAGE_SCHEME=rootless

    DEB_OUT="$(rename_sparkle_deb rootless)"

    echo -e "\033[1m\033[32mDone, we hope you enjoy Sparkle!\033[0m\n\nOutput deb: ${DEB_OUT}"

elif [ "$1" == "rootful" ];
then

    # Clean build artifacts
    make clean
    rm -rf .theos

    echo -e '\033[1m\033[32mBuilding Sparkle tweak for rootful\033[0m'

    # Empty scheme = rootful. Must be a command-line assignment: `unset` here is
    # useless because ~/.config/theos/rc.mk sets the scheme as a makefile
    # variable, and those win over the environment.
    ensure_ffmpeg_frameworks
    make package THEOS_PACKAGE_SCHEME=

    DEB_OUT="$(rename_sparkle_deb rootful)"

    echo -e "\033[1m\033[32mDone, we hope you enjoy Sparkle!\033[0m\n\nOutput deb: ${DEB_OUT}"

else
    echo '+--------------------+'
    echo '|Sparkle Build Script|'
    echo '+--------------------+'
    echo
    echo 'Usage: ./build.sh <rootless|rootful|sideload>'
    echo
    echo '  rootless - Build a rootless .deb package'
    echo '  rootful  - Build a rootful .deb package'
    echo '  ipa      - Build a patched IPA'
    echo
    echo 'When building an IPA, use at least one of the following flags:'
    echo '  --release         equivalent to --inject --patch'
    echo '  --inject          build Sparkle and pass its .deb to Cyan'
    echo '  --bundle          pass Sparkle.bundle + FFmpeg frameworks to Cyan, without the tweak'
    echo '  --no-ffmpeg       stage Sparkle.bundle without the FFmpeg frameworks'
    echo '  --flex            include libFLEX.dylib'
    echo '  --patch           run ipapatch'
    echo '  --no-ext          remove all .appex bundles before final injection'
    echo '  --dev             DEV=1 build'
    echo '  --buildonly       build the deb and dylibs only, skip IPA'
    echo '  --bundle-id <id>  override bundle ID'
    echo
    echo 'Examples:'
    echo '    ./build.sh ipa --release'
    echo '    ./build.sh ipa --release --flex'
    echo '    ./build.sh ipa --release --no-ext'
    echo '    ./build.sh ipa --bundle --flex --no-ext   (base IPA for LiveContainer dev)'
    echo '    ./build.sh ipa --bundle    (resource-only base IPA, no load commands)'
    echo
    echo 'Output names:'
    echo '    IPA  Sparkle[_<flags>]_v<version>_IG_v<ig version>.ipa'
    echo '    deb  Sparkle_v<version>_<rootless|rootful>.deb'
    echo
    exit 1
fi

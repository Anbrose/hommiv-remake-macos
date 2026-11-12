#!/bin/bash
# Build the iPhone app (ios/H4Remake.xcodeproj, generated from the shared sources).
#
#   ./make_ios.sh                  Release build for the simulator -> build/ios/H4Remake.app
#   ./make_ios.sh run [args...]    ... then install it on the simulator ($H4_SIM, default
#                                  "iPhone 15 Pro"), copy the game data into its Documents
#                                  (once; $H4DATA, default the Wine install's Data and maps)
#                                  and launch it, e.g. ./make_ios.sh run campaign:10:0
#   ./make_ios.sh data             copy the data into the installed simulator app again
#   ./make_ios.sh device           Release build for your own iPhone with the game data inside
#                                  the app (needs H4_TEAM_ID, e.g. a free Personal Team), then
#                                  installs and launches it on the connected iPhone ($H4_DEVICE,
#                                  default the first one devicectl lists); H4_BUNDLE_DATA=0 leaves
#                                  the data out (then copy it in through the Files app)
#   ./make_ios.sh archive          an .xcarchive for App Store Connect (needs H4_TEAM_ID)
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-build}"; [ $# -gt 0 ] && shift
BUNDLE_ID="${H4_BUNDLE_ID:-com.anbrose.h4remake}"
SIM="${H4_SIM:-iPhone 15 Pro}"
DATA="${H4DATA:-$HOME/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data}"
DERIVED=build/ios/derived
python3 ios/gen_xcodeproj.py
xb() { xcodebuild -project ios/H4Remake.xcodeproj -scheme H4Remake -configuration Release -derivedDataPath "$DERIVED" "$@"; }

copy_data() {
    local c; c=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)
    mkdir -p "$c/Documents"
    if [ ! -f "$c/Documents/Data/heroes4.h4r" ] || [ "${1:-}" = force ]; then
        echo "copying $DATA -> $c/Documents/Data"
        rsync -a --delete "$DATA/" "$c/Documents/Data/"
        [ -d "$DATA/../maps" ] && rsync -a --delete "$DATA/../maps/" "$c/Documents/maps/"
    fi
    echo "data in $c/Documents"
}

case "$MODE" in
build|run|data)
    if [ "$MODE" != data ]; then
        mkdir -p build/ios
        if ! xb -sdk iphonesimulator -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build > build/ios/build.log 2>&1; then
            grep -E "error:" build/ios/build.log | sort -u; echo "build failed (build/ios/build.log)"; exit 1
        fi
        APP="$DERIVED/Build/Products/Release-iphonesimulator/H4Remake.app"
        rm -rf build/ios/H4Remake.app; cp -R "$APP" build/ios/
        codesign --force --sign - build/ios/H4Remake.app >/dev/null 2>&1   # ad hoc: enough for the simulator
        echo "created build/ios/H4Remake.app"
    fi
    if [ "$MODE" != build ]; then
        xcrun simctl boot "$SIM" 2>/dev/null || true
        open -a Simulator 2>/dev/null || true   # (Xcode 27 may ship without the Simulator window app; the device runs headless)
        [ "$MODE" = run ] && xcrun simctl install "$SIM" build/ios/H4Remake.app
        copy_data $([ "$MODE" = data ] && echo force)
        if [ "$MODE" = run ]; then
            xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
            xcrun simctl launch "$SIM" "$BUNDLE_ID" "$@"
        fi
    fi
    ;;
device)
    export H4_BUNDLE_DATA="${H4_BUNDLE_DATA:-1}" H4DATA="$DATA" H4MAPS="$(dirname "$DATA")/maps"
    xb -sdk iphoneos -destination "generic/platform=iOS" -allowProvisioningUpdates build
    APPDIR="$DERIVED/Build/Products/Release-iphoneos/H4Remake.app"
    DEV="${H4_DEVICE:-$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c 'import json,sys
t=sys.stdin.read(); d=json.loads(t[t.index("{"):]) if "{" in t else {}
ok=[x["identifier"] for x in d.get("result",{}).get("devices",[]) if x.get("hardwareProperties",{}).get("platform")=="iOS" and x.get("hardwareProperties",{}).get("reality")!="simulated" and x.get("connectionProperties",{}).get("tunnelState")!="unavailable"]
print(ok[0] if ok else "")' || true)}"
    if [ -z "$DEV" ]; then echo "built $APPDIR; no connected iPhone found (set H4_DEVICE to its identifier)"; exit 0; fi
    xcrun devicectl device install app --device "$DEV" "$APPDIR"
    xcrun devicectl device process launch --device "$DEV" "$BUNDLE_ID" "$@" || echo "installed; open it on the phone (trust the developer in Settings > General > VPN & Device Management first)"
    ;;
archive)
    xb -sdk iphoneos -destination "generic/platform=iOS" -allowProvisioningUpdates archive -archivePath build/ios/H4Remake.xcarchive
    echo "created build/ios/H4Remake.xcarchive (upload: xcodebuild -exportArchive ... or Xcode's Organizer)"
    ;;
*) echo "usage: $0 [build|run [args...]|data|device|archive]"; exit 2 ;;
esac

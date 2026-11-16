#!/bin/bash
# R1 setup: builds the HD first-person app, signs it with the personal team and installs it.
# Run this again when the signature expires. Keep the Vision Pro on and unlocked.
# Release: a Debug build turns grpc-swift state assertions into crashes; on 2026-11-16 the app
# crashed when it wrote to a stream the robot side had just closed. Release throws instead.
# pipefail: a failed build must stop here instead of installing a stale app through `| tail`.
set -eo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
device=00008112-001250882184A01E
data="$HOME/Library/Developer/Xcode/DerivedData/TrackingStreamerHD"
cd "$here"
xcodebuild -project "Tracking Streamer.xcodeproj" -scheme VisionProTeleop -configuration Release -destination "id=$device" \
  -derivedDataPath "$data" -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation \
  DEVELOPMENT_TEAM=SRVJVMZ2WS CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=local.r1.TrackingStreamer.srvjvmz2ws \
  -skipPackageUpdates -disableAutomaticPackageResolution build | tail -3
app="$data/Build/Products/Release-xros/Tracking Streamer.app"
security cms -D -i "$app/embedded.mobileprovision" | plutil -extract ExpirationDate raw - | sed 's/^/signature expires /'
xcrun devicectl device install app --device "$device" "$app" | tail -3

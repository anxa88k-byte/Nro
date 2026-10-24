#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT_PATH:-$ROOT/Unity-iPhone.xcodeproj}"
SCHEME="${SCHEME:-}"
CONFIG="Release"
METHOD="${1:-unsigned}"
TEAM="${DEVELOPMENT_TEAM:-}"
BUNDLE_ID="${BUNDLE_ID:-app.pink8905.cyan510}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# Normalize the old Xcode ID that does not match the working signing profile.
if [[ "$BUNDLE_ID" == "com.DefaultCompany.Nro-------V---c" || "$BUNDLE_ID" == "com.DefaultCompan.Nro-------V---c" ]]; then
  BUNDLE_ID="app.pink8905.cyan5188"
fi
OUT="$ROOT/ios-build/out"
ARCHIVE="$OUT/NgocRongVua.xcarchive"
EXPORT_DIR="$OUT/ipa"
APP_NAME="$(basename "$PROJECT")"
APP_NAME="${APP_NAME%.*}"
UNITY_PROJECT="false"
if [[ "$PROJECT" == "$ROOT/Unity-iPhone.xcodeproj" ]]; then
  UNITY_PROJECT="true"
  SCHEME="${SCHEME:-Unity-iPhone}"
  APP_NAME="NgocRongVua"
fi
IPA_NAME="${IPA_NAME:-$APP_NAME}"
IPA_NAME="${IPA_NAME%.[iI][pP][aA]}"
if [[ ! "$IPA_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "LOI: ten IPA khong hop le. Chi dung 1-64 chu cai, chu so, cham, gach ngang hoac gach duoi." >&2
  exit 1
fi

next_ipa_path() {
  local candidate="$OUT/$IPA_NAME.ipa"
  local suffix=2
  while [[ -e "$candidate" ]]; do
    candidate="$OUT/$IPA_NAME-$suffix.ipa"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$candidate"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "LOI: script nay phai chay tren macOS co Xcode. Windows/Linux khong tao duoc .ipa." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "LOI: khong tim thay xcodebuild. Cai Xcode roi chay: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

if [[ ! -d "$PROJECT" ]]; then
  echo "LOI: khong tim thay Xcode project/workspace: $PROJECT" >&2
  exit 1
fi

# Fix this project's previously used Bundle ID in its Xcode/plist settings
# before Xcode signs the app. Keep the same ID in the build setting below.
PROJECT_DIR="$(dirname "$PROJECT")"
python3 - "$PROJECT_DIR" <<'PY'
import pathlib, sys

root = pathlib.Path(sys.argv[1])
old_values = (b"com.DefaultCompany.Nro-------V---c", b"com.DefaultCompan.Nro-------V---c")
new = b"app.pink8905.cyan5188"
extensions = {".pbxproj", ".plist", ".entitlements", ".xcconfig"}
changed = 0
for path in root.rglob("*"):
    if path.suffix not in extensions or not path.is_file():
        continue
    try:
        data = path.read_bytes()
    except OSError:
        continue
    if any(old in data for old in old_values):
        for old in old_values:
            data = data.replace(old, new)
        path.write_bytes(data)
        changed += 1
if changed:
    print(f"==> Bundle Identifier cu da duoc sua trong {changed} file Xcode/plist.")
PY
echo "==> Bundle Identifier se dung: $BUNDLE_ID"

if [[ "$PROJECT" == *.xcworkspace ]]; then
  PROJECT_ARGS=(-workspace "$PROJECT")
else
  PROJECT_ARGS=(-project "$PROJECT")
fi
if [[ -z "$SCHEME" ]]; then
  SCHEME="$(xcodebuild -list -json "${PROJECT_ARGS[@]}" | python3 -c 'import json,sys; d=json.load(sys.stdin); p=next(iter(d.values())); print((p.get("schemes") or [""])[0])')"
fi
if [[ -z "$SCHEME" ]]; then
  echo "LOI: khong tim thay scheme Xcode trong $PROJECT" >&2
  exit 1
fi

# Kiem tra 2 thu vien tinh cua Unity (luu bang Git LFS) truoc khi build, de bao loi ro
# rang thay vi loi kho hieu "The source path ... does not exist" tu il2cpp.
for lib in Libraries/libiPhone-lib.a Libraries/libil2cpp.a; do
  [[ "$UNITY_PROJECT" == "true" ]] || break
  path="$ROOT/$lib"
  if [[ ! -f "$path" ]]; then
    echo "LOI: thieu $lib." >&2
    echo "     File nay duoc luu bang Git LFS: chay 'git lfs install && git lfs pull'," >&2
    echo "     va dam bao .gitignore KHONG loai Libraries/*.a." >&2
    exit 1
  fi
  if [[ "$(head -c 8 "$path")" != "!<arch>" ]]; then
    echo "LOI: $lib khong phai file ar that ($(wc -c < "$path") byte) - nhieu kha nang la LFS pointer chua tai ve." >&2
    echo "     Chay: git lfs pull" >&2
    exit 1
  fi
done

case "$METHOD" in
  unsigned)         OVERRIDES=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" ENTITLEMENTS_REQUIRED=NO) ;;
  development)      OVERRIDES=() ;;
  ad-hoc)           OVERRIDES=() ;;
  app-store-connect) OVERRIDES=() ;;
  app-store)        OVERRIDES=() ;;
  *) echo "LOI: method khong hop le: $METHOD (unsigned|development|ad-hoc|app-store-connect)" >&2; exit 1 ;;
esac

if [[ "$METHOD" != "unsigned" && -z "$TEAM" ]]; then
  echo "LOI: thieu DEVELOPMENT_TEAM. Vi du: DEVELOPMENT_TEAM=ABCDE12345 ./ios-build/build-ipa.sh $METHOD" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

SETTINGS=(
  "${PROJECT_ARGS[@]}"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -destination "generic/platform=iOS"
  BUILD_NUMBER="$BUILD_NUMBER"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [[ "$UNITY_PROJECT" == "true" ]]; then
  # Dat ten app qua PRODUCT_NAME_APP; khong override PRODUCT_NAME vi no se doi
  # ten UnityFramework.framework va lam hong cac import <UnityFramework/...>.
  SETTINGS+=(PRODUCT_NAME_APP="$APP_NAME")
fi
[[ -n "$BUNDLE_ID" ]] && SETTINGS+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
[[ -n "$TEAM" ]] && SETTINGS+=(DEVELOPMENT_TEAM="$TEAM")
[[ "$METHOD" != "unsigned" ]] && SETTINGS+=(-allowProvisioningUpdates)

if [[ "$METHOD" == "unsigned" ]]; then
  echo "==> Build khong ky (unsigned)"
  xcodebuild "${SETTINGS[@]}" -derivedDataPath "$OUT/DerivedData" \
    "${OVERRIDES[@]}" \
    build
  PRODUCTS_DIR="$OUT/DerivedData/Build/Products/$CONFIG-iphoneos"
  APP="$PRODUCTS_DIR/$APP_NAME.app"
  if [[ ! -d "$APP" ]]; then
    # Bao ve truong hop project/scheme van ghi de PRODUCT_NAME_APP bang ten cu.
    mapfile -t BUILT_APPS < <(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' -print)
    if [[ "${#BUILT_APPS[@]}" -eq 1 ]]; then
      APP="${BUILT_APPS[0]}"
      APP_NAME="$(basename "$APP" .app)"
      echo "CANH BAO: Xcode tao ${APP_NAME}.app; se dung app nay de dong goi."
    else
      echo "LOI: khong tim thay $APP sau khi build" >&2
      echo "     Cac app da tao trong $PRODUCTS_DIR:" >&2
      printf '     %s\n' "${BUILT_APPS[@]:-khong co}" >&2
      exit 1
    fi
  fi
  # The unsigned IPA is later signed by tools such as eSign. Set the app's
  # actual Info.plist value here (before any signer applies its signature),
  # rather than relying only on Xcode build-setting overrides.
  python3 - "$APP/Info.plist" "$BUNDLE_ID" <<'PY'
import plistlib, sys

path, bundle_id = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    info = plistlib.load(f)
info["CFBundleIdentifier"] = bundle_id
with open(path, "wb") as f:
    plistlib.dump(info, f, sort_keys=False)
with open(path, "rb") as f:
    actual = plistlib.load(f).get("CFBundleIdentifier", "")
if actual != bundle_id:
    raise SystemExit(f"LOI: khong dat duoc CFBundleIdentifier: {actual}")
print(f"==> Bundle Identifier trong app: {actual}")
PY
  rm -rf "$OUT/Payload"
  mkdir -p "$OUT/Payload"
  cp -R "$APP" "$OUT/Payload/"
  IPA_PATH="$(next_ipa_path)"
  IPA_FILE="$(basename "$IPA_PATH")"
  (cd "$OUT" && zip -qry "$IPA_FILE" Payload)
  rm -rf "$OUT/Payload"
  echo "==> Xong: $IPA_PATH"
  exit 0
fi

echo "==> Archive (method: $METHOD, team: $TEAM)"
xcodebuild "${SETTINGS[@]}" -archivePath "$ARCHIVE" archive

ARCHIVED_APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$ARCHIVED_APP" ]]; then
  echo "LOI: khong tim thay app trong archive de kiem tra Bundle Identifier." >&2
  exit 1
fi
ARCHIVED_BUNDLE_ID="$(python3 - "$ARCHIVED_APP/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f).get("CFBundleIdentifier", ""))
PY
)"
if [[ "$ARCHIVED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "LOI: IPA du kien dung Bundle ID '$BUNDLE_ID' nhung archive tao '$ARCHIVED_BUNDLE_ID'." >&2
  exit 1
fi
echo "==> Da xac nhan Bundle Identifier trong app da ky: $ARCHIVED_BUNDLE_ID"

PLIST="$OUT/ExportOptions-$METHOD.plist"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$METHOD</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>compileBitcode</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST_EOF

echo "==> Export .ipa"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PLIST" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

BUILT_IPA="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
if [[ -z "$BUILT_IPA" ]]; then
  echo "LOI: khong tim thay .ipa trong $EXPORT_DIR" >&2
  exit 1
fi
IPA_PATH="$(next_ipa_path)"
mv "$BUILT_IPA" "$IPA_PATH"
echo "==> Xong: $IPA_PATH"

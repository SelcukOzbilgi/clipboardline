#!/bin/bash
# Self-built developer application only. Official release signing is separate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: bash scripts/build-community.sh [debug|release]" >&2; exit 2 ;; esac
case "${CLIPBOARDLINE_BUNDLE_MODELS:-0}" in 0|1) ;; *) echo "CLIPBOARDLINE_BUNDLE_MODELS must be 0 or 1" >&2; exit 2 ;; esac
test -f Sources/Tendedero/main.swift || { echo "Run from a complete ClipBoardLine source checkout" >&2; exit 1; }
# Identity overrides for separate self-built bundles (see scripts/build-fork.sh).
# The defaults are the upstream developer bundle.
APP_NAME="${CLIPBOARDLINE_APP_NAME:-ClipBoardLine Dev}"
BUNDLE_ID="${CLIPBOARDLINE_BUNDLE_ID:-org.clipboardline.community}"
STORAGE="${CLIPBOARDLINE_STORAGE_FOLDER:-ClipBoardLine Dev/Screenshots}"
RECOVERY_SUITE="${CLIPBOARDLINE_RECOVERY_SUITE:-org.clipboardline.community.recovery}"
VERSION="${CLIPBOARDLINE_VERSION:-0.0.0}"
BUILD_NUMBER="${CLIPBOARDLINE_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${CLIPBOARDLINE_SIGN_IDENTITY:--}"
LINK_PREVIEWS="${CLIPBOARDLINE_LINK_PREVIEWS_DEFAULT:-0}"
python3 - "$APP_NAME" "$BUNDLE_ID" "$STORAGE" "$RECOVERY_SUITE" "$VERSION" "$BUILD_NUMBER" "$LINK_PREVIEWS" <<'PY'
import re, sys
name, bundle, storage, suite, version, build, previews = sys.argv[1:]
part = r'[A-Za-z0-9][A-Za-z0-9 ._-]*'
domain = r'[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+'
checks = [
    (re.fullmatch(part, name), 'CLIPBOARDLINE_APP_NAME'),
    (re.fullmatch(domain, bundle) and bundle != 'local.clipboardline.review', 'CLIPBOARDLINE_BUNDLE_ID (never the official ID)'),
    (re.fullmatch(part + '(/' + part + ')*', storage) and '..' not in storage
        and not storage.startswith('Tendedero'), 'CLIPBOARDLINE_STORAGE_FOLDER (never the official folder)'),
    (re.fullmatch(domain, suite) and suite != 'local.clipboardline.recovery', 'CLIPBOARDLINE_RECOVERY_SUITE (never the official suite)'),
    (re.fullmatch(r'[0-9]+(\.[0-9]+){0,2}', version), 'CLIPBOARDLINE_VERSION'),
    (re.fullmatch(r'[0-9]+', build), 'CLIPBOARDLINE_BUILD_NUMBER'),
    (previews in ('0', '1'), 'CLIPBOARDLINE_LINK_PREVIEWS_DEFAULT (0 or 1)'),
]
for ok, label in checks:
    if not ok:
        raise SystemExit('Invalid ' + label)
PY
OUT="$ROOT/.build/community"
APP="$ROOT/build/$APP_NAME.app"
FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$OUT/Sources" "$OUT/ModuleCache" "$ROOT/build"
if [ -L "$APP" ] || [ -L "$OUT/Sources" ]; then
  echo "Refusing a symbolic-link development output" >&2; exit 1
fi
rm -rf "$OUT/Sources"
mkdir -p "$OUT/Sources"
swift package resolve
test -d "$FRAMEWORK" || { echo "The pinned Sparkle 2.10.0 framework is missing" >&2; exit 1; }
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported build architecture" >&2; exit 1 ;; esac

python3 - "$ROOT" "$OUT" "$STORAGE" "$RECOVERY_SUITE" "$LINK_PREVIEWS" <<'PY'
import pathlib, sys
root, out = map(pathlib.Path, sys.argv[1:3])
storage, suite, previews = sys.argv[3:]
for source in sorted((root / 'Sources/Tendedero').glob('*.swift')):
    text = source.read_text()
    if source.name == 'Inbox.swift':
        previous = '"Tendedero/Screenshots"'
        if text.count(previous) != 1:
            raise SystemExit('Review the development-only storage namespace before building')
        text = text.replace(previous, '"' + storage + '"')
    if source.name == 'LinkMetadataService.swift':
        previous = 'UserDefaults.standard.object(forKey: "linkMetadataEnabled") as? Bool ?? true'
        if text.count(previous) != 1:
            raise SystemExit('Review the development-only link-preview default before building')
        text = text.replace(previous, 'UserDefaults.standard.object(forKey: "linkMetadataEnabled") as? Bool ?? ' + ('true' if previews == '1' else 'false'))
    text = text.replace('Tendedero', 'ClipBoardLine')
    text = text.replace('"tshirt"', '"doc.on.clipboard"').replace('"tshirt.fill"', '"doc.on.clipboard.fill"')
    text = text.replace('"local.clipboardline.recovery"', '"' + suite + '"')
    (out / 'Sources' / source.name).write_text(text)
PY
OPT=(-O)
if [ "$CONFIG" = debug ]; then OPT=(-Onone -g); fi
swiftc "${OPT[@]}" -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx14.0" \
  -file-prefix-map "$ROOT=." -module-cache-path "$OUT/ModuleCache" \
  -F "$(dirname "$FRAMEWORK")" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$OUT"/Sources/*.swift -o "$OUT/ClipBoardLine"

# Refuse an unrelated target. The builder never installs or launches anything.
if [ -e "$APP" ]; then
  python3 - "$APP" "$BUNDLE_ID" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
if app.is_symlink() or not app.is_dir():
    raise SystemExit('The development output is not a normal application directory')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != sys.argv[2]:
    raise SystemExit('Refusing to replace a different application')
PY
fi
STAGE="$OUT/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$OUT/ClipBoardLine" "$STAGE/Contents/MacOS/ClipBoardLine"
ditto "$FRAMEWORK" "$STAGE/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$STAGE/Contents/Resources/LICENSE-Sparkle.txt"
cp "$ROOT/LICENSE" "$STAGE/Contents/Resources/LICENSE.txt"
for document in THIRD_PARTY_NOTICES.md PRIVACY.md SECURITY.md; do
  if [ -f "$ROOT/$document" ]; then cp "$ROOT/$document" "$STAGE/Contents/Resources/$document"; fi
done

swiftc -sdk "$SDK" -file-prefix-map "$ROOT=." scripts/make-review-icon.swift -o "$OUT/make-icon"
"$OUT/make-icon" "$OUT/icon.png"
sips -z 512 512 "$OUT/icon.png" --out "$OUT/icon512.png" >/dev/null
python3 - "$ROOT" "$OUT" "$STAGE" "$APP_NAME" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" <<'PY'
import pathlib, plistlib, struct, sys
root, out, app = map(pathlib.Path, sys.argv[1:4])
name, bundle, version, build = sys.argv[4:]
records = []
for kind, path in [(b'ic09', out / 'icon512.png'), (b'ic10', out / 'icon.png')]:
    data = path.read_bytes()
    records.append(kind + struct.pack('>I', len(data) + 8) + data)
body = b''.join(records)
(app / 'Contents/Resources/ClipBoardLine.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
languages = []
for folder in sorted((root / 'Sources/Tendedero/Resources').glob('*.lproj')):
    languages.append(folder.stem)
    destination = app / 'Contents/Resources' / folder.name
    destination.mkdir()
    (destination / 'Localizable.strings').write_text((folder / 'Localizable.strings').read_text().replace('Tendedero', 'ClipBoardLine'))
info = {
    'CFBundleName': name, 'CFBundleDisplayName': name,
    'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'ClipBoardLine',
    'CFBundleIconFile': 'ClipBoardLine', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version, 'CFBundleVersion': build,
    'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': languages,
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
    'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False,
    'UTExportedTypeDeclarations': [{'UTTypeIdentifier': 'local.clipboardline.library-id',
        'UTTypeConformsTo': ['public.data'], 'UTTypeDescription': 'Library item identifier'}],
    'NSDesktopFolderUsageDescription': name + ' watches the screenshot folder you choose.',
    'NSDocumentsFolderUsageDescription': name + ' watches only image folders you choose.',
    'NSDownloadsFolderUsageDescription': name + ' watches only image folders you choose.'
}
# No official feed, update key, credential helper or private signing profile is
# embedded. Both installed updater paths reject this development bundle ID.
for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
    if not isinstance(info[key], str) or not info[key]:
        raise SystemExit(key + ' must be a nonempty string')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
if [ "${CLIPBOARDLINE_BUNDLE_MODELS:-0}" = 1 ]; then
  bash scripts/bundle-search-models.sh "$STAGE"
fi

# Ad-hoc (or a local self-signed identity via CLIPBOARDLINE_SIGN_IDENTITY) is
# ONLY for this separate bundle. Never use this script to replace the official
# application's fixed release identity.
EMBEDDED="$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$SIGN_IDENTITY" --options 0 --timestamp=none "$EMBEDDED/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN_IDENTITY" --options 0 --timestamp=none --preserve-metadata=entitlements "$EMBEDDED/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN_IDENTITY" --options 0 --timestamp=none "$EMBEDDED/Autoupdate"
codesign --force --sign "$SIGN_IDENTITY" --options 0 --timestamp=none "$EMBEDDED/Updater.app"
codesign --force --sign "$SIGN_IDENTITY" --options 0 --timestamp=none "$STAGE/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" --options 0 --timestamp=none "$STAGE"
codesign --verify --deep --strict "$STAGE"
if [ -d "$APP" ]; then rm -rf "$APP"; fi
ditto "$STAGE" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
echo "Separate developer app; official updates disabled. Not installed or launched."

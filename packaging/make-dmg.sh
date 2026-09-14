#!/bin/bash
#
# Build a distributable macOS disk image for Sun notes.
#
#   packaging/make-dmg.sh [--release] [--version X.Y.Z] [--outdir DIR]
#                         [--no-build] [--no-icon-padding] [--keep-app]
#
# --release builds with dune's release profile instead of dev (no dev-only
# flags, js_of_ocaml output optimised) and strips the binary. Use it for
# anything you hand to someone else.
#
# Produces dist/Sun-notes-<version>-arm64.dmg containing "Sun notes.app" and a
# shortcut to /Applications.
#
# The bundle layout is dictated by how the executable finds its page:
# Webview.Utils.web_dir () looks for a "web" directory *next to the running
# binary*. The assets themselves live in Contents/Resources/web/, with a
# symlink at Contents/MacOS/web pointing to them, because codesign refuses to
# seal data files sitting directly in Contents/MacOS.
#
# The app is signed ad-hoc (codesign -s -). That is enough for it to run on
# this machine and on any Mac where the user clears the quarantine attribute,
# but it is not notarised: see the notice placed inside the image.

set -euo pipefail

# ---------------------------------------------------------------- parameters

APP_NAME="Sun notes"           # user-visible name, and the .app basename
BUNDLE_EXEC="sun-notes"        # Contents/MacOS/<this>
BUNDLE_ID="com.korkorran.sun-notes"
MIN_MACOS="11.0"
COPYRIGHT="© 2026 Frédéric Lang. MIT licence."
ICON_PAD_PCT=10                # transparent margin, to match Apple's icon grid

VERSION=""
OUTDIR=""
DO_BUILD=1
KEEP_APP=0
PROFILE="dev"
STRIP=0

# ------------------------------------------------------------------ plumbing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version)       VERSION="${2:?--version needs an argument}"; shift 2 ;;
    -o|--outdir)        OUTDIR="${2:?--outdir needs an argument}"; shift 2 ;;
    --release)          PROFILE="release"; STRIP=1; shift ;;
    --no-build)         DO_BUILD=0; shift ;;
    --no-icon-padding)  ICON_PAD_PCT=0; shift ;;
    --keep-app)         KEEP_APP=1; shift ;;
    -h|--help)          usage ;;
    *)                  die "unknown option: $1 (try --help)" ;;
  esac
done

OUTDIR="${OUTDIR:-$ROOT_DIR/dist}"

# Version: explicit flag, else the nearest git tag, else a placeholder.
if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${VERSION#v}"
  VERSION="${VERSION:-0.1.0}"
fi
# CFBundleVersion must be a dotted number; strip anything else from the tag.
BUILD_VERSION="$(printf '%s' "$VERSION" | sed 's/[^0-9.].*$//; s/^$/0/')"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sun-notes-dmg.XXXXXX")"
MOUNT_DIR=""
DEV_NODE=""
cleanup() {
  [ -n "$DEV_NODE" ] && hdiutil detach "$DEV_NODE" -quiet -force 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ------------------------------------------------- step 1: check the toolchain

step "Checking the environment"

[ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS"
HOST_ARCH="$(uname -m)"
[ "$HOST_ARCH" = "arm64" ] || die "expected an arm64 host, found $HOST_ARCH (this script packages an Apple Silicon build only)"

for tool in hdiutil sips iconutil codesign osascript rsync; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# Prefer the project's own opam switch: the dune on PATH belongs to whatever
# switch happens to be active and may be older than the (lang dune ...) this
# project declares, in which case it refuses to build at all.
if [ -n "${DUNE:-}" ]; then
  :
elif [ -x "$ROOT_DIR/_opam/bin/dune" ]; then
  DUNE="$ROOT_DIR/_opam/bin/dune"
elif command -v dune >/dev/null 2>&1; then
  DUNE="$(command -v dune)"
else
  DUNE=""
fi
if [ "$DO_BUILD" -eq 1 ]; then
  [ -n "$DUNE" ] || die "dune not found — install it, run 'opam switch create . --deps-only', or pass --no-build"
fi

SRC_ICON="$ROOT_DIR/logo.png"
[ -f "$SRC_ICON" ] || die "no logo.png at the repository root — the icon is built from it"

[ -n "$DUNE" ] && info "dune           $DUNE ($("$DUNE" --version 2>/dev/null))" || true
info "profile        $PROFILE$([ "$STRIP" -eq 1 ] && printf ' (binary stripped)')"
info "version        $VERSION (CFBundleVersion $BUILD_VERSION)"
info "output         $OUTDIR"
info "work directory $WORK_DIR"

# ------------------------------------------------------- step 2: build the app

BIN_SRC="$ROOT_DIR/_build/default/run/main.exe"
WEB_SRC="$ROOT_DIR/_build/default/run/web"

if [ "$DO_BUILD" -eq 1 ]; then
  step "Building with dune (--profile $PROFILE)"
  ( cd "$ROOT_DIR" && "$DUNE" build --profile "$PROFILE" )
else
  step "Skipping the build (--no-build)"
  [ "$PROFILE" = "release" ] && warn "--release with --no-build: whatever is already in _build is packaged as is, only the strip still applies" || true
fi

[ -x "$BIN_SRC" ] || die "no executable at $BIN_SRC — run without --no-build"
[ -f "$WEB_SRC/index.html" ] || die "no built page at $WEB_SRC/index.html"
[ -f "$WEB_SRC/app.js" ] || die "no compiled page at $WEB_SRC/app.js — did js_of_ocaml run?"

BIN_ARCH="$(lipo -archs "$BIN_SRC")"
case " $BIN_ARCH " in
  *" arm64 "*) : ;;
  *) die "the built binary is $BIN_ARCH, not arm64" ;;
esac
info "binary is $BIN_ARCH"

# Anything the binary links beyond the system frameworks would have to be
# copied in and relocated; fail loudly rather than ship a bundle that only
# works on a machine with opam installed.
NONSYSTEM="$(otool -L "$BIN_SRC" | tail -n +2 | awk '{print $1}' \
             | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)"
[ -z "$NONSYSTEM" ] || die "the binary links non-system libraries, which this script does not bundle:
$NONSYSTEM"

# ------------------------------------------------------- step 3: build the icon

step "Building the icon from logo.png"

ICONSET="$WORK_DIR/AppIcon.iconset"
MASTER="$WORK_DIR/icon-master.png"
mkdir -p "$ICONSET"

SRC_DIMS="$(sips -g pixelWidth -g pixelHeight "$SRC_ICON" | awk '/pixel/ {print $2}' | paste -sd'x' -)"
info "source is ${SRC_DIMS}px"

# A macOS app icon does not fill its tile: the artwork sits inside roughly 80%
# of it, so a full-bleed icon looks oversized in the Dock next to everything
# else. Pad it on a transparent 1024 canvas. Pillow is used when present
# because the resize has to be done in premultiplied alpha — otherwise the
# colour of the fully transparent pixels bleeds into the antialiased edge and
# the cutout gets a pale fringe back.
PADDED=0
if [ "$ICON_PAD_PCT" -gt 0 ] && python3 -c 'import PIL' >/dev/null 2>&1; then
  python3 - "$SRC_ICON" "$MASTER" "$ICON_PAD_PCT" <<'PY' && PADDED=1
import sys
from PIL import Image, ImageChops

src, dst, pct = sys.argv[1], sys.argv[2], float(sys.argv[3])
S = 1024
im = Image.open(src).convert("RGBA")
w, h = im.size
inner = max(1, round(S * (1 - 2 * pct / 100)))
scale = min(inner / w, inner / h)
nw, nh = max(1, round(w * scale)), max(1, round(h * scale))

r, g, b, a = im.split()
pre = Image.merge("RGBA", (ImageChops.multiply(r, a),
                           ImageChops.multiply(g, a),
                           ImageChops.multiply(b, a), a))
small = pre.resize((nw, nh), Image.LANCZOS)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
canvas.paste(small, ((S - nw) // 2, (S - nh) // 2))

out = []
for rr, gg, bb, aa in canvas.getdata():
    if aa == 0:
        out.append((0, 0, 0, 0))
    else:
        f = 255.0 / aa
        out.append((min(255, int(rr * f + 0.5)),
                    min(255, int(gg * f + 0.5)),
                    min(255, int(bb * f + 0.5)), aa))
res = Image.new("RGBA", (S, S))
res.putdata(out)
res.save(dst)
PY
fi

if [ "$PADDED" -eq 1 ]; then
  info "padded to a 1024px canvas with a ${ICON_PAD_PCT}% margin"
else
  [ "$ICON_PAD_PCT" -gt 0 ] && warn "python3 + Pillow not available: the icon will be full-bleed, which looks slightly oversized in the Dock" || true
  sips -s format png -z 1024 1024 "$SRC_ICON" --out "$MASTER" >/dev/null
fi

for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  size="${spec%%:*}"; name="${spec##*:}"
  sips -s format png -z "$size" "$size" "$MASTER" --out "$ICONSET/$name.png" >/dev/null
done

ICNS="$WORK_DIR/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"
info "wrote $(basename "$ICNS") ($(du -h "$ICNS" | cut -f1 | tr -d ' '))"

# ---------------------------------------------------- step 4: assemble the app

step "Assembling $APP_NAME.app"

APP="$WORK_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_SRC" "$CONTENTS/MacOS/$BUNDLE_EXEC"
chmod 755 "$CONTENTS/MacOS/$BUNDLE_EXEC"   # dune leaves build outputs read-only

# Strip local and debug symbols. OCaml keeps what it needs for backtraces in
# its own data sections, so this is safe; it has to happen before codesign,
# which the edit would otherwise invalidate.
if [ "$STRIP" -eq 1 ]; then
  before=$(stat -f%z "$CONTENTS/MacOS/$BUNDLE_EXEC")
  strip -x "$CONTENTS/MacOS/$BUNDLE_EXEC"
  after=$(stat -f%z "$CONTENTS/MacOS/$BUNDLE_EXEC")
  info "stripped: $((before / 1024))K -> $((after / 1024))K"
fi

# The page has to be reachable at <exe_dir>/web, because that is where
# Webview.Utils.web_dir looks. It cannot simply *live* there: codesign treats
# every file under Contents/MacOS as code to be sealed, and chokes on
# index.html ("code object is not signed at all"), which invalidates the whole
# bundle signature. So the assets live in Resources/, where they belong, and a
# symlink beside the binary points at them — that the signature accepts.
# Only the runtime assets: dune stages the OCaml sources in the same directory.
rsync -a \
  --exclude='.*' \
  --exclude='*.ml' --exclude='*.mli' --exclude='dune' \
  --exclude='*.bc.js' --exclude='*.bc-for-jsoo' \
  "$WEB_SRC/" "$CONTENTS/Resources/web/"
chmod -R u+w "$CONTENTS/Resources/web"
ln -s ../Resources/web "$CONTENTS/MacOS/web"

[ -f "$CONTENTS/MacOS/web/index.html" ] || die "index.html is not reachable at Contents/MacOS/web/"
[ -f "$CONTENTS/MacOS/web/app.js" ] || die "app.js is not reachable at Contents/MacOS/web/"
info "page: $(ls "$CONTENTS/Resources/web" | tr '\n' ' ')"

cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>          <string>en</string>
	<key>CFBundleDisplayName</key>                <string>$APP_NAME</string>
	<key>CFBundleExecutable</key>                 <string>$BUNDLE_EXEC</string>
	<key>CFBundleIconFile</key>                   <string>AppIcon</string>
	<key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
	<key>CFBundleName</key>                       <string>$APP_NAME</string>
	<key>CFBundlePackageType</key>                <string>APPL</string>
	<key>CFBundleShortVersionString</key>         <string>$VERSION</string>
	<key>CFBundleVersion</key>                    <string>$BUILD_VERSION</string>
	<key>LSApplicationCategoryType</key>          <string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>             <string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key>            <true/>
	<key>NSHumanReadableCopyright</key>           <string>$COPYRIGHT</string>
	<!-- The app browses a folder the user picks; these strings are what macOS
	     shows if that folder is one of the protected locations. -->
	<key>NSDesktopFolderUsageDescription</key>    <string>Sun notes needs access to open and save the notes you keep on your Desktop.</string>
	<key>NSDocumentsFolderUsageDescription</key>  <string>Sun notes needs access to open and save the notes you keep in Documents.</string>
	<key>NSDownloadsFolderUsageDescription</key>  <string>Sun notes needs access to open and save the notes you keep in Downloads.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

plutil -lint "$CONTENTS/Info.plist" >/dev/null || die "generated Info.plist is malformed"

# --------------------------------------------------------- step 5: sign ad-hoc

step "Signing ad-hoc"

# Ad-hoc (-s -) costs nothing and needs no account. On Apple Silicon every
# binary must carry at least this signature to launch at all; what it does not
# do is satisfy Gatekeeper on a machine that downloaded the image, hence the
# notice added to the disk image below.
xattr -cr "$APP"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# ------------------------------------------------------ step 6: stage the image

step "Staging the disk image contents"

STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

NOTICE="$STAGE/Lisez-moi — Read me.txt"
cat > "$NOTICE" <<NOTICE_EOF
$APP_NAME $VERSION
==================

Installation
    Glissez « $APP_NAME » sur le dossier Applications, à droite.
    Drag "$APP_NAME" onto the Applications folder on the right.

Première ouverture / First launch
    Cette application est signée ad-hoc, pas notarisée par Apple. Au premier
    lancement macOS refusera de l'ouvrir. Faites un clic droit sur l'app dans
    le dossier Applications, puis choisissez « Ouvrir » et confirmez. Une seule
    fois : les lancements suivants sont normaux.

    This application is ad-hoc signed and not notarised by Apple, so macOS will
    refuse to open it the first time. Right-click the app in Applications,
    choose "Open", and confirm. You only have to do this once.

    Équivalent en ligne de commande / command-line equivalent:
        xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app"

Configuration requise / Requirements
    macOS $MIN_MACOS or later, Apple Silicon (arm64).

$COPYRIGHT
https://github.com/korkorran/Sun-notes
NOTICE_EOF

# Give the mounted volume the app's icon too.
cp "$ICNS" "$STAGE/.VolumeIcon.icns"

# ------------------------------------------------------ step 7: create the DMG

step "Creating the disk image"

VOL_NAME="$APP_NAME"
DMG_BASENAME="$(printf '%s' "$APP_NAME" | tr ' ' '-')-$VERSION-arm64"
RW_DMG="$WORK_DIR/rw.dmg"
FINAL_DMG="$OUTDIR/$DMG_BASENAME.dmg"

# Size the read-write image from the payload with room to spare: the Finder
# writes a .DS_Store into it, and HFS+ needs slack of its own.
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) * 3 / 2 + 20000 ))

rm -f "$RW_DMG"
hdiutil create \
  -srcfolder "$STAGE" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${SIZE_KB}k" \
  "$RW_DMG" >/dev/null

# Do not assume /Volumes/$VOL_NAME: if a volume of that name is already
# mounted (a previous build of this very image, say), the new one lands on
# "$VOL_NAME 1" and every step below would act on the wrong volume — laying out
# the window of a read-only image and leaving this one attached. Read back
# where it actually went, and keep the device node to detach by.
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DEV_NODE="$(printf '%s\n' "$ATTACH_OUT" | awk '/\/Volumes\// {print $1; exit}')"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUT" \
             | awk 'match($0, /\/Volumes\//) {print substr($0, RSTART); exit}' \
             | sed 's/[[:space:]]*$//')"
sleep 1
[ -n "$DEV_NODE" ] && [ -d "$MOUNT_DIR" ] || die "the image did not mount:
$ATTACH_OUT"

VOL_MOUNTED="$(basename "$MOUNT_DIR")"
info "mounted $DEV_NODE on $MOUNT_DIR"
[ "$VOL_MOUNTED" = "$VOL_NAME" ] || warn "a volume named \"$VOL_NAME\" was already mounted, so this one is \"$VOL_MOUNTED\" — the layout is applied to the right one, but unmount the other before the next build"

# ---------------------------------------------------- step 8: lay out the window

step "Laying out the window"

# Best-effort: this drives the Finder through AppleScript, which needs
# Automation permission and is the one part that can legitimately fail on a
# fresh machine or a headless session. A plain image is still a valid image.
if ! osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOL_MOUNTED"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 900, 580}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set position of item "$APP_NAME.app" of container window to {170, 190}
    set position of item "Applications" of container window to {510, 190}
    set position of item "$(basename "$NOTICE")" of container window to {340, 360}
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT
then
  warn "could not drive the Finder (Automation permission?) — the image keeps the default layout"
else
  info "window sized, icons positioned"
fi

# Mark the volume as having a custom icon. SetFile ships with the Xcode command
# line tools and may be absent; the icon is cosmetic, so do not fail over it.
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_DIR" || warn "could not set the custom-icon flag on the volume"
else
  warn "SetFile not found — the mounted volume keeps the generic disk icon"
fi

sync
for attempt in 1 2 3 4 5; do
  if hdiutil detach "$DEV_NODE" -quiet 2>/dev/null; then MOUNT_DIR=""; break; fi
  [ "$attempt" = 5 ] && die "could not unmount $MOUNT_DIR — close any Finder window showing it and retry"
  sleep 2
done

# Detaching returns before the kernel has finished releasing the backing file,
# and hdiutil convert on a still-attached image fails with EAGAIN.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  hdiutil info | grep -qF "$RW_DMG" || { DEV_NODE=""; break; }
  [ "$attempt" = 10 ] && die "the image is still attached after detaching it"
  sleep 1
done

# ------------------------------------------------------- step 9: compress & sign

step "Compressing"

mkdir -p "$OUTDIR"
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
codesign --force --sign - "$FINAL_DMG"
hdiutil verify "$FINAL_DMG" >/dev/null

if [ "$KEEP_APP" -eq 1 ]; then
  rm -rf "${OUTDIR:?}/$APP_NAME.app"
  cp -R "$APP" "$OUTDIR/"
  info "kept $OUTDIR/$APP_NAME.app"
fi

step "Done"
info "$FINAL_DMG"
info "$(du -h "$FINAL_DMG" | cut -f1 | tr -d ' ')"
printf '\n    Try it with:  open "%s"\n\n' "$FINAL_DMG"

#!/bin/bash
#
# Build a distributable Debian package for Sun notes.
#
#   packaging/make-deb.sh [--release] [--version X.Y.Z] [--outdir DIR]
#                         [--no-build] [--keep-tree]
#
# --release builds with dune's release profile instead of dev (no dev-only
# flags, js_of_ocaml output optimised) and strips the binary. Use it for
# anything you hand to someone else.
#
# Produces dist/sun-notes_<version>_<arch>.deb.
#
# Unlike the macOS bundle, nothing is embedded: the binary links GTK3 and
# webkit2gtk-4.1 dynamically, and the package simply declares them. The
# versioned dependencies are computed from the ELF by dpkg-shlibdeps rather
# than written by hand, so they track whatever the binary actually needs —
# including the glibc floor, which is set by the machine this runs on.
#
# The layout is dictated by how the executable finds its page:
# Webview.Utils.web_dir () looks for a "web" directory *next to the running
# binary*, which is not where the FHS wants a program's data. So the binary
# and its assets live together in /usr/lib/sun-notes/, and /usr/bin/sun-notes
# is a symlink to it: OCaml resolves Sys.executable_name through
# /proc/self/exe, so the symlink lands on the real directory and web/ is found
# beside it.

set -euo pipefail

# ---------------------------------------------------------------- parameters

PKG_NAME="sun-notes"           # Debian package name, and /usr/lib/<this>
APP_NAME="Sun notes"           # user-visible name
BUNDLE_EXEC="sun-notes"        # the installed executable
MAINTAINER="Frédéric Lang <frederic.ln.lang@gmail.com>"
HOMEPAGE="https://github.com/korkorran/Sun-notes"
SECTION="editors"
SYNOPSIS="note-taking app written in OCaml"
ICON_SIZES="16 24 32 48 64 128 256 512"

VERSION=""
OUTDIR=""
DO_BUILD=1
KEEP_TREE=0
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
    -v|--version)   VERSION="${2:?--version needs an argument}"; shift 2 ;;
    -o|--outdir)    OUTDIR="${2:?--outdir needs an argument}"; shift 2 ;;
    --release)      PROFILE="release"; STRIP=1; shift ;;
    --no-build)     DO_BUILD=0; shift ;;
    --keep-tree)    KEEP_TREE=1; shift ;;
    -h|--help)      usage ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
done

OUTDIR="${OUTDIR:-$ROOT_DIR/dist}"

# Version: explicit flag, else the nearest git tag, else a placeholder. A
# Debian version has to start with a digit, so a leading "v" goes.
if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${VERSION#v}"
  VERSION="${VERSION:-0.1.0}"
fi
VERSION="${VERSION#v}"
case "$VERSION" in
  [0-9]*) : ;;
  *) die "version \"$VERSION\" does not start with a digit, which Debian requires" ;;
esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sun-notes-deb.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ------------------------------------------------- step 1: check the toolchain

step "Checking the environment"

[ "$(uname -s)" = "Linux" ] || die "this script only runs on Linux (use make-dmg.sh on macOS)"

for tool in dpkg dpkg-deb find md5sum gzip; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

DEB_ARCH="$(dpkg --print-architecture)"

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
[ -f "$SRC_ICON" ] || die "no logo.png at the repository root — the icons are built from it"

[ -n "$DUNE" ] && info "dune           $DUNE ($("$DUNE" --version 2>/dev/null))" || true
info "profile        $PROFILE$([ "$STRIP" -eq 1 ] && printf ' (binary stripped)')"
info "version        $VERSION"
info "architecture   $DEB_ARCH"
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

# ------------------------------------------------- step 3: inspect the binary

step "Inspecting the binary"

# The package claims one architecture in its filename and its control file;
# make sure the ELF agrees, rather than shipping an amd64-labelled arm64 build.
case "$DEB_ARCH" in
  amd64) WANT_MACHINE="X86-64" ;;
  arm64) WANT_MACHINE="AArch64" ;;
  armhf) WANT_MACHINE="ARM" ;;
  i386)  WANT_MACHINE="Intel 80386" ;;
  *)     WANT_MACHINE="" ;;
esac
if [ -n "$WANT_MACHINE" ] && command -v readelf >/dev/null 2>&1; then
  BIN_MACHINE="$(readelf -h "$BIN_SRC" | awk -F: '/Machine:/ {sub(/^[ \t]+/, "", $2); print $2; exit}')"
  case "$BIN_MACHINE" in
    *"$WANT_MACHINE"*) info "ELF machine is $BIN_MACHINE" ;;
    *) die "dpkg says this host is $DEB_ARCH but the binary is $BIN_MACHINE" ;;
  esac
fi

# Anything linked from outside the system directories would not exist on the
# user's machine. In practice this catches a library picked up from the opam
# switch, from /usr/local, or from a home directory — fail loudly rather than
# ship a package that only works here.
if command -v ldd >/dev/null 2>&1; then
  MISSING="$(ldd "$BIN_SRC" 2>/dev/null | awk '/not found/ {print $1}' || true)"
  [ -z "$MISSING" ] || die "the binary links libraries that are not installed here:
$MISSING"
  FOREIGN="$(ldd "$BIN_SRC" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3}' \
             | grep -v -e '^/lib/' -e '^/usr/lib/' || true)"
  [ -z "$FOREIGN" ] || die "the binary links libraries from outside the system directories, which this script does not bundle:
$FOREIGN"
  info "links $(ldd "$BIN_SRC" 2>/dev/null | grep -c '=>' || true) shared libraries, all from system paths"
fi

# ------------------------------------------------------ step 4: build the icons

step "Building the icons from logo.png"

# Freedesktop wants one PNG per size under hicolor. Downscaling is done by
# whatever is available; ImageMagick first, then Pillow. Without either, only
# the source size is installed, which still works — the toolkit just does the
# scaling itself, less well.
ICON_DIR="$WORK_DIR/icons"
mkdir -p "$ICON_DIR"

SRC_DIM="$(python3 -c 'import sys
from struct import unpack
with open(sys.argv[1], "rb") as f:
    f.read(16)
    w, h = unpack(">II", f.read(8))
print("%dx%d" % (w, h))' "$SRC_ICON" 2>/dev/null || echo "unknown")"
info "source is ${SRC_DIM}px"

RESIZE=""
if command -v magick >/dev/null 2>&1; then RESIZE="magick"
elif command -v convert >/dev/null 2>&1; then RESIZE="convert"
elif python3 -c 'import PIL' >/dev/null 2>&1; then RESIZE="pillow"
fi

case "$RESIZE" in
  magick|convert)
    for size in $ICON_SIZES; do
      "$RESIZE" "$SRC_ICON" -resize "${size}x${size}" -strip "PNG32:$ICON_DIR/$size.png"
    done
    info "resized with ImageMagick ($RESIZE): $ICON_SIZES"
    ;;
  pillow)
    python3 - "$SRC_ICON" "$ICON_DIR" $ICON_SIZES <<'PY'
import sys
from PIL import Image, ImageChops

src, dst, sizes = sys.argv[1], sys.argv[2], [int(s) for s in sys.argv[3:]]
im = Image.open(src).convert("RGBA")

# Resize in premultiplied alpha, otherwise the colour of the fully transparent
# pixels bleeds into the antialiased edge and the cutout gets a pale fringe.
r, g, b, a = im.split()
pre = Image.merge("RGBA", (ImageChops.multiply(r, a),
                           ImageChops.multiply(g, a),
                           ImageChops.multiply(b, a), a))
for size in sizes:
    small = pre.resize((size, size), Image.LANCZOS)
    out = []
    for rr, gg, bb, aa in small.getdata():
        if aa == 0:
            out.append((0, 0, 0, 0))
        else:
            f = 255.0 / aa
            out.append((min(255, int(rr * f + 0.5)),
                        min(255, int(gg * f + 0.5)),
                        min(255, int(bb * f + 0.5)), aa))
    res = Image.new("RGBA", (size, size))
    res.putdata(out)
    res.save("%s/%d.png" % (dst, size))
PY
    info "resized with Pillow: $ICON_SIZES"
    ;;
  *)
    case "$SRC_DIM" in
      512x512) cp "$SRC_ICON" "$ICON_DIR/512.png"
               warn "neither ImageMagick nor Pillow found — installing the 512px icon only" ;;
      *) warn "neither ImageMagick nor Pillow found and logo.png is ${SRC_DIM}, not a standard size — the package will have no icon" ;;
    esac
    ;;
esac

# ------------------------------------------------- step 5: assemble the tree

step "Assembling the package tree"

TREE="$WORK_DIR/tree"
LIBDIR="$TREE/usr/lib/$PKG_NAME"
DOCDIR="$TREE/usr/share/doc/$PKG_NAME"
mkdir -p "$LIBDIR" "$TREE/usr/bin" "$TREE/usr/share/applications" "$DOCDIR"

install -m 755 "$BIN_SRC" "$LIBDIR/$BUNDLE_EXEC"

# OCaml keeps what it needs for backtraces in its own data sections, so this
# is safe, and Debian expects shipped binaries to be stripped.
if [ "$STRIP" -eq 1 ]; then
  if command -v strip >/dev/null 2>&1; then
    before=$(stat -c%s "$LIBDIR/$BUNDLE_EXEC")
    strip --strip-unneeded "$LIBDIR/$BUNDLE_EXEC"
    after=$(stat -c%s "$LIBDIR/$BUNDLE_EXEC")
    info "stripped: $((before / 1024))K -> $((after / 1024))K"
  else
    warn "strip not found — the binary keeps its symbols"
  fi
fi

# The page has to sit at <exe_dir>/web, because that is where
# Webview.Utils.web_dir looks. Only the runtime assets: dune stages the OCaml
# sources of the page in the same build directory.
mkdir -p "$LIBDIR/web"
cp -R "$WEB_SRC/." "$LIBDIR/web/"
chmod -R u+w "$LIBDIR/web"
find "$LIBDIR/web" \
  \( -name '*.ml' -o -name '*.mli' -o -name 'dune' \
     -o -name '*.bc.js' -o -name '*.bc-for-jsoo' -o -name '.?*' \) \
  -exec rm -rf {} +

[ -f "$LIBDIR/web/index.html" ] || die "index.html is not reachable at $LIBDIR/web/"
[ -f "$LIBDIR/web/app.js" ] || die "app.js is not reachable at $LIBDIR/web/"
info "page: $(ls "$LIBDIR/web" | tr '\n' ' ')"

# /usr/bin is what is on PATH, but the binary must stay next to web/. A
# symlink is enough: OCaml's Sys.executable_name goes through /proc/self/exe,
# which resolves it, so exe_dir () is /usr/lib/sun-notes either way.
ln -s "../lib/$PKG_NAME/$BUNDLE_EXEC" "$TREE/usr/bin/$BUNDLE_EXEC"

for size in $ICON_SIZES; do
  [ -f "$ICON_DIR/$size.png" ] || continue
  dest="$TREE/usr/share/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$dest"
  install -m 644 "$ICON_DIR/$size.png" "$dest/$PKG_NAME.png"
done

# main.ml takes no arguments and opens no file given on the command line, so
# no %F and no MimeType here: claiming to handle a file it would ignore is
# worse than claiming nothing. StartupWMClass lets the shell match the window
# back to this entry, since GTK names it after the executable.
cat > "$TREE/usr/share/applications/$PKG_NAME.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=Note editor
Comment=A $SYNOPSIS
Exec=$BUNDLE_EXEC
Icon=$PKG_NAME
Terminal=false
Categories=Office;Utility;TextEditor;
Keywords=notes;markdown;editor;
StartupWMClass=$BUNDLE_EXEC
DESKTOP
chmod 644 "$TREE/usr/share/applications/$PKG_NAME.desktop"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$TREE/usr/share/applications/$PKG_NAME.desktop" \
    || die "the generated .desktop file is not valid"
  info "desktop entry validates"
fi

# Debian wants a changelog under /usr/share/doc, gzipped. The version carries
# no Debian revision, which makes this a "native" package, and a native
# package's changelog is changelog.gz — not changelog.Debian.gz. -n keeps the
# timestamp out of the gzip header, so the same input gives the same bytes.
cat > "$WORK_DIR/changelog" <<CHANGELOG
$PKG_NAME ($VERSION) unstable; urgency=medium

  * Sun notes $VERSION. See $HOMEPAGE/releases for the changes.

 -- $MAINTAINER  $(date -R)
CHANGELOG
gzip -9n -c "$WORK_DIR/changelog" > "$DOCDIR/changelog.gz"
chmod 644 "$DOCDIR/changelog.gz"

{
  printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n'
  printf 'Upstream-Name: %s\n' "$PKG_NAME"
  printf 'Source: %s\n\n' "$HOMEPAGE"
  printf 'Files: *\n'
  printf 'Copyright: %s\n' "$(sed -n 's/^Copyright (c) //p' "$ROOT_DIR/LICENSE" | head -1)"
  printf 'License: MIT\n'
  sed -n '/^Permission is hereby granted/,$p' "$ROOT_DIR/LICENSE" \
    | sed 's/[[:space:]]*$//; s/^$/./; s/^/ /'
} > "$DOCDIR/copyright"
chmod 644 "$DOCDIR/copyright"

# Uniform, predictable permissions: dune leaves its outputs read-only, and cp
# carries that through.
find "$TREE" -type d -exec chmod 755 {} +
find "$TREE" -type f -exec chmod 644 {} +
chmod 755 "$LIBDIR/$BUNDLE_EXEC"

# Policy counts the payload only; DEBIAN/ is created after this on purpose.
INSTALLED_SIZE="$(du -sk "$TREE" | cut -f1)"

# ------------------------------------------------- step 6: work out the depends

step "Computing the dependencies"

DEPENDS=""
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
  # dpkg-shlibdeps reads the ELF and turns each DT_NEEDED into the package
  # that ships it, with the minimum version the used symbols require — which
  # is how the glibc floor ends up being the one of the build machine rather
  # than a guess. It insists on finding debian/control relative to the current
  # directory, so give it a minimal one.
  mkdir -p "$WORK_DIR/debian"
  cat > "$WORK_DIR/debian/control" <<CONTROL
Source: $PKG_NAME
Section: $SECTION
Priority: optional
Maintainer: $MAINTAINER

Package: $PKG_NAME
Architecture: any
Description: $SYNOPSIS
CONTROL
  if DEPENDS="$( cd "$WORK_DIR" && dpkg-shlibdeps -O \
                   "$TREE/usr/lib/$PKG_NAME/$BUNDLE_EXEC" 2>"$WORK_DIR/shlibdeps.log" )"; then
    DEPENDS="${DEPENDS#shlibs:Depends=}"
    info "from dpkg-shlibdeps: $DEPENDS"
  else
    warn "dpkg-shlibdeps failed:"
    sed 's/^/    /' "$WORK_DIR/shlibdeps.log" >&2
    DEPENDS=""
  fi
else
  warn "dpkg-shlibdeps not found (install dpkg-dev) — falling back to a hand-written dependency list"
fi

if [ -z "$DEPENDS" ]; then
  # The versions are the ones owebview's depexts imply: webkit2gtk-4.1 is the
  # libsoup3 series, which means Debian 12 / Ubuntu 22.04 and later. No libc6
  # floor here, because a hand-written one would be a guess.
  DEPENDS="libc6, libgtk-3-0 (>= 3.22), libwebkit2gtk-4.1-0 (>= 2.36)"
  info "assuming: $DEPENDS"
fi

case "$DEPENDS" in
  *libwebkit2gtk-4.1*) : ;;
  *) warn "the computed dependencies do not mention libwebkit2gtk-4.1 — check that the binary really links the GTK backend" ;;
esac

# ------------------------------------------------- step 7: write the metadata

step "Writing the control files"

mkdir -p "$TREE/DEBIAN"

# The extended description is indented by one space, with " ." for the blank
# lines; that is the format, not a style choice.
cat > "$TREE/DEBIAN/control" <<CONTROL
Package: $PKG_NAME
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: $MAINTAINER
Installed-Size: $INSTALLED_SIZE
Depends: $DEPENDS
Section: $SECTION
Priority: optional
Homepage: $HOMEPAGE
Description: $SYNOPSIS
 A desktop note-taking application written entirely in OCaml, both sides of
 it. The window is a native one rendered by the system web engine through
 webkit2gtk; the page inside it is OCaml too, compiled to JavaScript with
 js_of_ocaml and driven by ocaml-vdom in the Elm style, so the whole interface
 is a pure function of a model.
 .
 Browse a directory as a tree, open several files at once as tabs, edit them
 and write them back.
 .
 The native side answers the page over the webview bridge, and does so on an
 Lwt event loop of its own rather than on the UI thread: a slow disk, a
 network mount or a large file cannot freeze the window, and several calls
 interleave instead of queuing behind each other.
CONTROL
chmod 644 "$TREE/DEBIAN/control"

# md5sums lists regular files only — not the symlink in /usr/bin, and not
# DEBIAN/ itself.
( cd "$TREE" && find . -type f -not -path './DEBIAN/*' -printf '%P\0' \
  | sort -z | xargs -0 -r md5sum > DEBIAN/md5sums )
chmod 644 "$TREE/DEBIAN/md5sums"
info "control: $INSTALLED_SIZE KiB installed, $(wc -l < "$TREE/DEBIAN/md5sums") files"

# ------------------------------------------------- step 8: build the package

step "Building the package"

mkdir -p "$OUTDIR"
FINAL_DEB="$OUTDIR/${PKG_NAME}_${VERSION}_${DEB_ARCH}.deb"
rm -f "$FINAL_DEB"

# Everything must be owned by root in the archive. --root-owner-group does
# that without fakeroot; it needs dpkg >= 1.19 (Debian 10), so fall back.
BUILD_CMD=(dpkg-deb -Zxz --build)
if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
  BUILD_CMD=(dpkg-deb --root-owner-group -Zxz --build)
elif command -v fakeroot >/dev/null 2>&1; then
  BUILD_CMD=(fakeroot dpkg-deb -Zxz --build)
  info "using fakeroot (this dpkg-deb has no --root-owner-group)"
else
  warn "neither --root-owner-group nor fakeroot: the files will be owned by $(id -un) in the archive"
fi

# xz explicitly: a zstd-compressed .deb, which some dpkg builds default to,
# will not install on an older dpkg.
"${BUILD_CMD[@]}" "$TREE" "$FINAL_DEB"

# ------------------------------------------------------- step 9: verify

step "Verifying"

dpkg-deb --info "$FINAL_DEB" | sed 's/^/    /'
info ""
dpkg-deb --contents "$FINAL_DEB" | awk '{print $1, $2, $6, $7, $8}' | sed 's/^/    /'

if command -v lintian >/dev/null 2>&1; then
  info ""
  # Informational tags only: this is not going into the Debian archive, and
  # the ones that fire here are about that (no source package, no watch file).
  lintian --no-tag-display-limit --suppress-tags \
    no-manual-page,no-copyright-file,extended-description-is-probably-too-short \
    "$FINAL_DEB" 2>&1 | sed 's/^/    /' || warn "lintian reported the above"
else
  warn "lintian not found — skipping the policy check"
fi

if [ "$KEEP_TREE" -eq 1 ]; then
  rm -rf "${OUTDIR:?}/${PKG_NAME}_tree"
  cp -R "$TREE" "$OUTDIR/${PKG_NAME}_tree"
  info "kept $OUTDIR/${PKG_NAME}_tree"
fi

step "Done"
info "$FINAL_DEB"
info "$(du -h "$FINAL_DEB" | cut -f1 | tr -d ' ')"
printf '\n    Install it with:  sudo apt install "%s"\n\n' "$FINAL_DEB"

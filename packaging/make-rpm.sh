#!/bin/bash
#
# Build a distributable RPM package for Sun notes.
#
#   packaging/make-rpm.sh [--release] [--version X.Y.Z] [--outdir DIR]
#                         [--no-build] [--keep-tree]
#
# --release builds with dune's release profile instead of dev (no dev-only
# flags, js_of_ocaml output optimised) and strips the binary. Use it for
# anything you hand to someone else.
#
# Produces dist/sun-notes-<version>-1.<dist>.<arch>.rpm.
#
# As with the Debian package, nothing is embedded: the binary links GTK3 and
# webkit2gtk-4.1 dynamically. The difference is that nothing here has to ask
# for the dependencies either — rpmbuild's automatic dependency generator
# reads the ELF itself and emits soname requirements such as
# libwebkit2gtk-4.1.so.0()(64bit). That is better than naming packages: the
# same RPM then resolves on Fedora, RHEL and openSUSE, which spell the
# webkit2gtk package three different ways.
#
# The layout is the one the Debian package uses, moved to where Fedora keeps
# such things: Webview.Utils.web_dir () looks for a "web" directory *next to
# the running binary*, so the binary and its assets live together in
# %{_libexecdir}/sun-notes/ and /usr/bin/sun-notes is a symlink to it. OCaml
# resolves Sys.executable_name through /proc/self/exe, which follows the
# symlink, so the assets are found either way.

set -euo pipefail

# ---------------------------------------------------------------- parameters

PKG_NAME="sun-notes"
APP_NAME="Sun notes"
BUNDLE_EXEC="sun-notes"
APP_ID="io.github.korkorran.sun-notes"   # AppStream component id
PACKAGER="Frédéric Lang <frederic.ln.lang@gmail.com>"
HOMEPAGE="https://github.com/korkorran/Sun-notes"
SYNOPSIS="Note-taking app written in OCaml"
RPM_LICENSE="MIT"
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

# Version: explicit flag, else the nearest git tag, else a placeholder.
if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${VERSION#v}"
  VERSION="${VERSION:-0.1.0}"
fi
VERSION="${VERSION#v}"

# A hyphen separates Version from Release in an RPM's filename, so it cannot
# appear in either. Anything else the deb script would accept is fine.
case "$VERSION" in
  *-*)
    SAFE_VERSION="${VERSION//-/.}"
    warn "RPM versions cannot contain '-': using $SAFE_VERSION instead of $VERSION"
    VERSION="$SAFE_VERSION"
    ;;
esac
case "$VERSION" in
  [0-9]*) : ;;
  *) die "version \"$VERSION\" does not start with a digit" ;;
esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sun-notes-rpm.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ------------------------------------------------- step 1: check the toolchain

step "Checking the environment"

[ "$(uname -s)" = "Linux" ] || die "this script only runs on Linux (use make-dmg.sh on macOS)"

command -v rpmbuild >/dev/null 2>&1 || die "rpmbuild not found — install it (dnf install rpm-build)"
command -v rpm >/dev/null 2>&1 || die "rpm not found"
command -v tar >/dev/null 2>&1 || die "tar not found"

RPM_ARCH="$(rpm --eval '%{_arch}')"
DIST_TAG="$(rpm --eval '%{?dist}')"

# %{?dist} is empty on a distribution that does not define it — the package
# still builds, but its filename will not say which distribution it targets,
# and the automatic requirements were resolved against this machine's
# libraries. Building on the Fedora you target is the point.
if [ -z "$DIST_TAG" ]; then
  warn "this host defines no %{?dist} macro — is this really a Fedora/RHEL system? The package will be built without a distribution tag"
fi

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
[ -f "$ROOT_DIR/LICENSE" ] || die "no LICENSE at the repository root — %license needs it"

[ -n "$DUNE" ] && info "dune           $DUNE ($("$DUNE" --version 2>/dev/null))" || true
info "profile        $PROFILE$([ "$STRIP" -eq 1 ] && printf ' (binary stripped)')"
info "version        $VERSION-1$DIST_TAG"
info "architecture   $RPM_ARCH"
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

case "$RPM_ARCH" in
  x86_64)  WANT_MACHINE="X86-64" ;;
  aarch64) WANT_MACHINE="AArch64" ;;
  armv7hl) WANT_MACHINE="ARM" ;;
  i686)    WANT_MACHINE="Intel 80386" ;;
  *)       WANT_MACHINE="" ;;
esac
if [ -n "$WANT_MACHINE" ] && command -v readelf >/dev/null 2>&1; then
  BIN_MACHINE="$(readelf -h "$BIN_SRC" | awk -F: '/Machine:/ {sub(/^[ \t]+/, "", $2); print $2; exit}')"
  case "$BIN_MACHINE" in
    *"$WANT_MACHINE"*) info "ELF machine is $BIN_MACHINE" ;;
    *) die "rpm says this host is $RPM_ARCH but the binary is $BIN_MACHINE" ;;
  esac
fi

if command -v ldd >/dev/null 2>&1; then
  MISSING="$(ldd "$BIN_SRC" 2>/dev/null | awk '/not found/ {print $1}' || true)"
  [ -z "$MISSING" ] || die "the binary links libraries that are not installed here:
$MISSING"
  FOREIGN="$(ldd "$BIN_SRC" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3}' \
             | grep -v -e '^/lib/' -e '^/lib64/' -e '^/usr/lib/' -e '^/usr/lib64/' || true)"
  [ -z "$FOREIGN" ] || die "the binary links libraries from outside the system directories, which this script does not bundle:
$FOREIGN"
  info "links $(ldd "$BIN_SRC" 2>/dev/null | grep -c '=>' || true) shared libraries, all from system paths"
fi

# ------------------------------------------------------ step 4: build the icons

step "Building the icons from logo.png"

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

# ------------------------------------------------- step 5: assemble the payload

step "Assembling the payload"

# Ask rpm where things go rather than hardcoding: _libexecdir is /usr/libexec
# on Fedora but /usr/lib on some others, and getting it wrong would put the
# files somewhere %files does not look.
BINDIR="$(rpm --eval '%{_bindir}')"
LIBEXECDIR="$(rpm --eval '%{_libexecdir}')"
DATADIR="$(rpm --eval '%{_datadir}')"

TREE="$WORK_DIR/$PKG_NAME-$VERSION"
PRIVDIR="$TREE$LIBEXECDIR/$PKG_NAME"
mkdir -p "$PRIVDIR" "$TREE$BINDIR" \
         "$TREE$DATADIR/applications" "$TREE$DATADIR/metainfo"

install -m 755 "$BIN_SRC" "$PRIVDIR/$BUNDLE_EXEC"

# OCaml keeps what it needs for backtraces in its own data sections, so this
# is safe. rpmbuild's brp-strip would do it anyway, but doing it here keeps
# --release meaning the same thing in all three packaging scripts.
if [ "$STRIP" -eq 1 ]; then
  if command -v strip >/dev/null 2>&1; then
    before=$(stat -c%s "$PRIVDIR/$BUNDLE_EXEC")
    strip --strip-unneeded "$PRIVDIR/$BUNDLE_EXEC"
    after=$(stat -c%s "$PRIVDIR/$BUNDLE_EXEC")
    info "stripped: $((before / 1024))K -> $((after / 1024))K"
  else
    warn "strip not found — the binary keeps its symbols"
  fi
fi

# Only the runtime assets: dune stages the OCaml sources of the page in the
# same build directory.
mkdir -p "$PRIVDIR/web"
cp -R "$WEB_SRC/." "$PRIVDIR/web/"
chmod -R u+w "$PRIVDIR/web"
find "$PRIVDIR/web" \
  \( -name '*.ml' -o -name '*.mli' -o -name 'dune' \
     -o -name '*.bc.js' -o -name '*.bc-for-jsoo' -o -name '.?*' \) \
  -exec rm -rf {} +

[ -f "$PRIVDIR/web/index.html" ] || die "index.html is not reachable at $PRIVDIR/web/"
[ -f "$PRIVDIR/web/app.js" ] || die "app.js is not reachable at $PRIVDIR/web/"
info "page: $(ls "$PRIVDIR/web" | tr '\n' ' ')"

# Relative, computed rather than assembled by hand: _bindir and _libexecdir
# are macros, so the number of ".." between them is not something to guess.
# -m resolves a path that does not exist yet, which is the case inside $TREE.
LINK_TARGET="$(realpath -m --relative-to="$BINDIR" "$LIBEXECDIR/$PKG_NAME/$BUNDLE_EXEC" 2>/dev/null \
               || printf '%s' "$LIBEXECDIR/$PKG_NAME/$BUNDLE_EXEC")"
ln -s "$LINK_TARGET" "$TREE$BINDIR/$BUNDLE_EXEC"
info "symlink: $BINDIR/$BUNDLE_EXEC -> $LINK_TARGET"

for size in $ICON_SIZES; do
  [ -f "$ICON_DIR/$size.png" ] || continue
  dest="$TREE$DATADIR/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$dest"
  install -m 644 "$ICON_DIR/$size.png" "$dest/$PKG_NAME.png"
done

# main.ml takes no argument and opens no file given on the command line, so no
# %F and no MimeType: claiming to handle a file it would ignore is worse than
# claiming nothing. StartupWMClass lets the shell match the window back to
# this entry, since GTK names it after the executable.
cat > "$TREE$DATADIR/applications/$PKG_NAME.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=Note editor
Comment=$SYNOPSIS
Exec=$BUNDLE_EXEC
Icon=$PKG_NAME
Terminal=false
Categories=Office;Utility;TextEditor;
Keywords=notes;markdown;editor;
StartupWMClass=$BUNDLE_EXEC
DESKTOP

# AppStream metadata. Without it the app installs and runs, but GNOME Software
# — which is how most Fedora users will meet it — has nothing to show: no
# description, no screenshot, and it may not list the app at all.
cat > "$TREE$DATADIR/metainfo/$APP_ID.metainfo.xml" <<METAINFO
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$APP_ID</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>$RPM_LICENSE</project_license>
  <name>$APP_NAME</name>
  <summary>$SYNOPSIS</summary>
  <description>
    <p>
      A desktop note-taking application written entirely in OCaml, both sides
      of it. The window is a native one rendered by the system web engine
      through webkit2gtk; the page inside it is OCaml too, compiled to
      JavaScript with js_of_ocaml and driven by ocaml-vdom in the Elm style,
      so the whole interface is a pure function of a model.
    </p>
    <p>
      Browse a directory as a tree, open several files at once as tabs, edit
      them and write them back.
    </p>
  </description>
  <launchable type="desktop-id">$PKG_NAME.desktop</launchable>
  <url type="homepage">$HOMEPAGE</url>
  <url type="bugtracker">$HOMEPAGE/issues</url>
  <screenshots>
    <screenshot type="default">
      <image>$HOMEPAGE/raw/main/screenshot.jpg</image>
      <caption>Editing notes in Sun notes</caption>
    </screenshot>
  </screenshots>
  <content_rating type="oars-1.1"/>
  <releases>
    <release version="$VERSION" date="$(date -u +%Y-%m-%d)"/>
  </releases>
</component>
METAINFO

# %license and %doc read these from the build directory, not the buildroot,
# so they ride along at the top of the tarball rather than under /usr.
cp "$ROOT_DIR/LICENSE" "$TREE/LICENSE"
DOC_LINE=""
if [ -f "$ROOT_DIR/README.md" ]; then
  cp "$ROOT_DIR/README.md" "$TREE/README.md"
  DOC_LINE="%doc README.md"
fi

find "$TREE" -type d -exec chmod 755 {} +
find "$TREE" -type f -exec chmod 644 {} +
chmod 755 "$PRIVDIR/$BUNDLE_EXEC"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$TREE$DATADIR/applications/$PKG_NAME.desktop" \
    || die "the generated .desktop file is not valid"
  info "desktop entry validates"
else
  warn "desktop-file-validate not found (install desktop-file-utils) — the desktop entry is not checked"
fi

if command -v appstream-util >/dev/null 2>&1; then
  appstream-util validate-relax --nonet "$TREE$DATADIR/metainfo/$APP_ID.metainfo.xml" \
    | sed 's/^/    /' || warn "appstream-util was not happy with the metainfo (see above)"
elif command -v appstreamcli >/dev/null 2>&1; then
  appstreamcli validate --no-net "$TREE$DATADIR/metainfo/$APP_ID.metainfo.xml" \
    | sed 's/^/    /' || warn "appstreamcli was not happy with the metainfo (see above)"
else
  warn "neither appstream-util nor appstreamcli found — the AppStream metadata is not checked"
fi

# ------------------------------------------------- step 6: write the spec

step "Writing the spec file"

TOPDIR="$WORK_DIR/rpmbuild"
mkdir -p "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

TARBALL="$PKG_NAME-$VERSION-tree.tar.gz"
( cd "$WORK_DIR" && tar czf "$TOPDIR/SOURCES/$TARBALL" "$PKG_NAME-$VERSION" )
info "payload tarball: $(du -h "$TOPDIR/SOURCES/$TARBALL" | cut -f1 | tr -d ' ')"

# %check is only emitted when the tool to run it exists, rather than making
# the spec fail on a machine without desktop-file-utils.
CHECK_SECTION=""
if command -v desktop-file-validate >/dev/null 2>&1; then
  CHECK_SECTION="%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{name}.desktop
"
fi

SPEC="$TOPDIR/SPECS/$PKG_NAME.spec"
cat > "$SPEC" <<SPEC_EOF
# The payload is the output of \`dune build\`, produced by make-rpm.sh before
# rpmbuild is even called: there is no %build section here. Consequently there
# are no debug symbols to extract into a -debuginfo subpackage, and asking for
# one would only make the build fail.
%global debug_package %{nil}
%global _missing_build_ids_terminate_build 0

Name:           $PKG_NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        $SYNOPSIS

License:        $RPM_LICENSE
URL:            $HOMEPAGE
Source0:        $TARBALL

# The interesting requirements are not here: rpmbuild's automatic dependency
# generator reads the ELF and emits the sonames it needs — among them
# libwebkit2gtk-4.1.so.0 and libgtk-3.so.0 — which resolve on any RPM distro
# regardless of how each one names the package that ships them. Only the icon
# theme has to be named, because that is a directory-ownership matter no
# scanner can infer.
Requires:       hicolor-icon-theme

%description
A desktop note-taking application written entirely in OCaml, both sides of it.
The window is a native one rendered by the system web engine through
webkit2gtk; the page inside it is OCaml too, compiled to JavaScript with
js_of_ocaml and driven by ocaml-vdom in the Elm style, so the whole interface
is a pure function of a model.

Browse a directory as a tree, open several files at once as tabs, edit them
and write them back.

The native side answers the page over the webview bridge, and does so on an
Lwt event loop of its own rather than on the UI thread: a slow disk, a network
mount or a large file cannot freeze the window, and several calls interleave
instead of queuing behind each other.

%prep
%setup -q

%build
# Nothing to do: see the comment at the top of this file.

%install
mkdir -p %{buildroot}
cp -a ./usr %{buildroot}/

$CHECK_SECTION
%files
%license LICENSE
$DOC_LINE
%{_bindir}/%{name}
%{_libexecdir}/%{name}/
%{_datadir}/applications/%{name}.desktop
%{_datadir}/icons/hicolor/*/apps/%{name}.png
%{_datadir}/metainfo/$APP_ID.metainfo.xml

# No %post scriptlets to refresh the icon cache or the desktop database:
# modern Fedora does both through file triggers in the packages that own
# those caches, and duplicating them here is now discouraged.

%changelog
* $(LC_ALL=C date -u '+%a %b %d %Y') $PACKAGER - $VERSION-1
- Sun notes $VERSION. See $HOMEPAGE/releases for the changes.
SPEC_EOF

info "spec: $SPEC"

# ------------------------------------------------- step 7: build the package

step "Building the package"

rpmbuild --define "_topdir $TOPDIR" -bb "$SPEC" 2>&1 | sed 's/^/    /'

BUILT="$(find "$TOPDIR/RPMS" -name '*.rpm' -type f | head -1)"
[ -n "$BUILT" ] || die "rpmbuild reported success but produced no .rpm under $TOPDIR/RPMS"

mkdir -p "$OUTDIR"
FINAL_RPM="$OUTDIR/$(basename "$BUILT")"
rm -f "$FINAL_RPM"
cp "$BUILT" "$FINAL_RPM"

# ------------------------------------------------------- step 8: verify

step "Verifying"

rpm -qip "$FINAL_RPM" | sed 's/^/    /'
info ""
info "Requires:"
rpm -qp --requires "$FINAL_RPM" | sed 's/^/        /'
info ""
info "Contents:"
rpm -qlp "$FINAL_RPM" | sed 's/^/        /'

# The dependency generator is the whole point of using RPM here; if it did not
# see webkit, something is wrong with the binary rather than with the spec.
if ! rpm -qp --requires "$FINAL_RPM" | grep -q 'libwebkit2gtk-4\.1'; then
  warn "the automatic requirements do not mention libwebkit2gtk-4.1 — check that the binary really links the GTK backend"
fi

if command -v rpmlint >/dev/null 2>&1; then
  info ""
  # Informational: this is a binary package built outside the Fedora build
  # system, so the tags about missing sources and hand-made layout are
  # expected rather than defects.
  rpmlint "$FINAL_RPM" 2>&1 | sed 's/^/    /' || warn "rpmlint reported the above"
else
  warn "rpmlint not found — skipping the policy check"
fi

if [ "$KEEP_TREE" -eq 1 ]; then
  rm -rf "${OUTDIR:?}/${PKG_NAME}_tree"
  cp -R "$TREE" "$OUTDIR/${PKG_NAME}_tree"
  cp "$SPEC" "$OUTDIR/$PKG_NAME.spec"
  info "kept $OUTDIR/${PKG_NAME}_tree and $OUTDIR/$PKG_NAME.spec"
fi

step "Done"
info "$FINAL_RPM"
info "$(du -h "$FINAL_RPM" | cut -f1 | tr -d ' ')"
printf '\n    Install it with:  sudo dnf install "%s"\n\n' "$FINAL_RPM"

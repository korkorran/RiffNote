# Packaging

| Script | Platform | Output |
|---|---|---|
| `make-dmg.sh` | macOS, Apple Silicon | `dist/Sun-notes-<version>-arm64.dmg` |
| `make-deb.sh` | Linux, Debian family | `dist/sun-notes_<version>_<arch>.deb` |
| `make-rpm.sh` | Linux, Fedora family | `dist/sun-notes-<version>-1.<dist>.<arch>.rpm` |

Each has to run *on* the platform it packages for; none of them cross-compile,
because `ocamlopt` has no `--target` and emits code for the host. Both Linux
packages are built, installed and checked in CI by
`.github/workflows/linux-package.yml`, which attaches them to the GitHub
release on a tag. The macOS image is still built by hand, since it needs a Mac.

The two Linux scripts share a layout and differ only where the distributions
do — see *Nothing is bundled* below, which applies to both.

# macOS — `make-dmg.sh`

`make-dmg.sh` builds a distributable macOS disk image: `dist/Sun-notes-<version>-arm64.dmg`,
containing `Sun notes.app` and a shortcut to `/Applications`.

```sh
./packaging/make-dmg.sh --release        # what you hand to someone else
./packaging/make-dmg.sh                  # dev profile, for a quick check
```

| Option | |
|---|---|
| `--release` | Build with dune's `release` profile and strip the binary. Without it, the `dev` profile is packaged as is. |
| `--version X.Y.Z` | Bundle version. Defaults to the nearest git tag, then to `0.1.0`. |
| `--outdir DIR` | Where to write the `.dmg`. Defaults to `dist/`. |
| `--no-build` | Package whatever is already in `_build/`. |
| `--no-icon-padding` | Keep the icon full-bleed instead of insetting it (see below). |
| `--keep-app` | Also leave the built `.app` next to the image. |

Requirements: macOS on Apple Silicon (the script packages an arm64 build only),
the project's opam switch, and Xcode command line tools. Everything else —
`hdiutil`, `sips`, `iconutil`, `codesign` — ships with the system. Pillow is
used for the icon if present; without it the icon is built full-bleed.

## What the script does

1. Builds with dune. It prefers `_opam/bin/dune` over whatever is on `PATH`:
   the `dune` of the ambient switch is easily older than the `(lang dune ...)`
   this project declares, and then nothing builds at all.
2. Turns `logo.png` into `AppIcon.icns`. The artwork is inset on a transparent
   1024 canvas (10% margin) because a macOS icon is not meant to fill its tile
   — full-bleed, it looks oversized next to everything else in the Dock. The
   resize is done in premultiplied alpha, otherwise the colour of the fully
   transparent pixels bleeds into the antialiased edge.
3. Assembles the bundle, signs it ad-hoc, builds the image, lays out its
   window through the Finder, and compresses it.

## Bundle layout

```
Sun notes.app/Contents/
├── Info.plist
├── MacOS/
│   ├── sun-notes            the executable
│   └── web -> ../Resources/web
└── Resources/
    ├── AppIcon.icns
    └── web/                 index.html, style.css, app.js
```

The symlink is the one surprising part, and it is load-bearing.
`Webview.Utils.web_dir` looks for a `web` directory *next to the running
binary*, so something has to be at `Contents/MacOS/web`. It cannot be the
assets themselves: `codesign` treats every file under `Contents/MacOS` as code
to seal, chokes on `index.html` (*"code object is not signed at all"*), and
invalidates the whole signature. A symlink satisfies both — `Sys.file_exists`
follows it, and the signature accepts it.

Only runtime assets are copied: dune stages the OCaml sources of the page in
the same build directory, and those are filtered out.

## Signing

The app is signed ad-hoc (`codesign -s -`), which costs nothing and needs no
Apple account. It is enough for the app to launch, but it is **not**
notarised, so a Mac that downloaded the image refuses to open it until the
user right-clicks the app and chooses *Open*, or clears the quarantine
attribute. The image carries a bilingual notice saying so.

Notarising instead would mean a Developer ID certificate, `codesign --options
runtime` with a hardened runtime, and a `xcrun notarytool submit` pass on the
finished image before stapling it — dropped in between the signing and
compression steps.


# Linux — `make-deb.sh`

`make-deb.sh` builds a Debian package: `dist/sun-notes_<version>_<arch>.deb`.

```sh
./packaging/make-deb.sh --release        # what you hand to someone else
./packaging/make-deb.sh                  # dev profile, for a quick check
```

| Option | |
|---|---|
| `--release` | Build with dune's `release` profile and strip the binary. Without it, the `dev` profile is packaged as is. |
| `--version X.Y.Z` | Package version. Defaults to the nearest git tag, then to `0.1.0`. A leading `v` is dropped, because a Debian version must start with a digit. |
| `--outdir DIR` | Where to write the `.deb`. Defaults to `dist/`. |
| `--no-build` | Package whatever is already in `_build/`. |
| `--keep-tree` | Also leave the unpacked tree next to the package, to inspect it. |

Requirements: a Linux machine of the architecture you are packaging for, the
project's opam switch, and `dpkg-dev` for `dpkg-shlibdeps`. ImageMagick or
Pillow is used to scale the icon; `desktop-file-utils` and `lintian` are used
to check the result if present. All of them are optional — the script says so
and carries on — except `dpkg-deb` itself.

## Nothing is bundled

This is the one real difference from the macOS image. The binary links GTK3
and webkit2gtk-4.1 dynamically and the package simply *declares* them, rather
than shipping a copy the way an AppImage or an Electron app would. The
consequence is that the dependency has to be exact, so the list is not written
by hand: `dpkg-shlibdeps` reads the ELF, maps each `DT_NEEDED` entry to the
package that ships it, and works out the minimum version from the symbols
actually used.

That includes the glibc floor, which comes from **the machine the package is
built on** — so the build host decides which distributions can install the
result. webkit2gtk-4.1 is the libsoup3 series, which means Debian 12 and
Ubuntu 22.04 at the earliest; of those, Ubuntu 22.04 has the oldest glibc,
which is why the workflow builds there. Building on something newer still
produces a working package, just one that installs on fewer machines.

## Layout

```
/usr/lib/sun-notes/
├── sun-notes                the executable
└── web/                     index.html, style.css, app.js
/usr/bin/sun-notes           -> ../lib/sun-notes/sun-notes
/usr/share/applications/sun-notes.desktop
/usr/share/icons/hicolor/<size>x<size>/apps/sun-notes.png
/usr/share/doc/sun-notes/{copyright,changelog.gz}
```

The symlink is the load-bearing part here, as it was on macOS, but for the
opposite reason. `Webview.Utils.web_dir` looks for a `web` directory *next to
the running binary*, which is not somewhere the FHS lets a program keep its
data — `/usr/bin` holds executables, not HTML. So both live together under
`/usr/lib/sun-notes/` and `/usr/bin/sun-notes` merely points there. It works
because OCaml resolves `Sys.executable_name` through `/proc/self/exe`, which
follows the symlink to the real file, so `exe_dir ()` is `/usr/lib/sun-notes`
however the program was invoked.

Only runtime assets are copied: dune stages the OCaml sources of the page in
the same build directory, and those are filtered out.

The desktop entry deliberately has no `%F` and no `MimeType`. `main.ml` reads
no command-line argument, so advertising the app as a handler for `.md` files
would have the desktop launch it and the file be silently ignored.

## Why a `.deb` and not an AppImage

An AppImage would have to carry WebKitGTK itself, which is the hard case: the
`WebKitNetworkProcess` and `WebKitWebProcess` helpers are found by absolute
path, they want `bwrap` for their sandbox, and the GIO modules, gdk-pixbuf
loaders and GLib schemas all have to come along. The failure mode is also
worse — a missing dependency surfaces as a blank window at runtime instead of
as a refusal to install.

A Flatpak would be the clean answer to that, since `org.gnome.Platform` ships
WebKitGTK, and is the natural next step if the package needs to reach distros
outside the Debian family. An `.rpm` is the same work as this script for a
much smaller audience, and with dependency names that differ per distribution
(`webkit2gtk4.1` on Fedora, `libwebkit2gtk-4_1-0` on openSUSE).


# Linux — `make-rpm.sh`

`make-rpm.sh` builds an RPM: `dist/sun-notes-<version>-1.<dist>.<arch>.rpm`.

```sh
./packaging/make-rpm.sh --release        # what you hand to someone else
./packaging/make-rpm.sh                  # dev profile, for a quick check
```

It takes the same options as `make-deb.sh`: `--release`, `--version X.Y.Z`,
`--outdir DIR`, `--no-build`, `--keep-tree` (which also keeps the generated
spec file, to read).

Requirements: a Fedora machine of the architecture you are packaging for, the
project's opam switch, and `rpm-build`. `desktop-file-utils`, `libappstream-glib`
(or `appstream`) and `rpmlint` are used to check the result if present; without
them the script says so and carries on. ImageMagick or Pillow scales the icon.

```sh
sudo dnf install rpm-build rpmlint desktop-file-utils libappstream-glib ImageMagick
```

## What differs from the Debian package

**The dependencies are not declared at all.** `make-deb.sh` has to run
`dpkg-shlibdeps` and write a `Depends:` line; rpmbuild's dependency generator
does the equivalent by itself, on every build, and there is no way to ask for
it. The spec therefore names only `hicolor-icon-theme`, which is a matter of
directory ownership that no ELF scanner can infer.

That turns out to be an advantage rather than a convenience. RPM requirements
come out as sonames — `libwebkit2gtk-4.1.so.0()(64bit)` — not package names,
so the same RPM resolves on Fedora, on RHEL and on openSUSE, which each call
the webkit2gtk package something different. The Debian package cannot do this:
`Depends:` names packages, so it is tied to one family's naming.

**The private directory moves.** Debian's `/usr/lib/sun-notes/` becomes
`%{_libexecdir}/sun-notes/`, which is `/usr/libexec/sun-notes/` on Fedora. The
script asks `rpm --eval` for the macro rather than hardcoding the path, and
computes the `/usr/bin/sun-notes` symlink with `realpath --relative-to` for the
same reason — the number of `..` between `_bindir` and `_libexecdir` is not
something to assume.

**There is an AppStream metainfo file.** `/usr/share/metainfo/` is how GNOME
Software learns that the package is an application: without it the app still
installs and runs, but Software has no description and no screenshot to show,
and may not list it at all. That file has no equivalent in the Debian package
because nothing on that side reads it by default.

**`%global debug_package %{nil}`.** The payload is built by dune before
rpmbuild is invoked, so there is no `%build` section and no debug symbols to
split into a `-debuginfo` subpackage. Asking for one would only fail the build.

## Publishing it

`.github/workflows/linux-package.yml` builds it in a `fedora:latest` container
on an Ubuntu runner (`build-rpm`), then installs it in a *clean* container of
the same image to check it (`verify-rpm`) — clean because the build container
has every `-devel` package installed and would satisfy the runtime
requirements by accident.

Two things worth knowing about that job. It uses `ocaml-system`, Fedora's own
compiler, rather than having opam build one, which saves several minutes on a
cold cache; if the system compiler is ever too old for this project, swap it
for `opam switch create . ocaml-base-compiler`. And the container image decides
the package's glibc floor, so whichever Fedora it builds in is the oldest one
the RPM will install on — the comment above the `image:` key explains why it is
not pinned to an older release the way the Debian build is.

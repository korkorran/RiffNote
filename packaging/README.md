# Packaging

| Script | Platform | Output |
|---|---|---|
| `make-dmg.sh` | macOS, Apple Silicon | `dist/Sun-notes-<version>-arm64.dmg` |
| `make-deb.sh` | Linux, Debian family | `dist/sun-notes_<version>_<arch>.deb` |
| `make-rpm.sh` | Linux, Fedora family | `dist/sun-notes-<version>-1.<dist>.<arch>.rpm` |
| `make-installer.ps1` | Windows | `dist/Sun-notes-<version>-<arch>-setup.exe` |

Each has to run *on* the platform it packages for; none of them cross-compile,
because `ocamlopt` has no `--target` and emits code for the host. The two Linux
packages and the Windows installer each have their own CI workflow —
`.github/workflows/{deb,rpm,windows}.yml` — which builds it, installs it to
check it, and publishes it to the GitHub release.

## How publishing works

**Pushing to the `releases` branch is what publishes.** Nothing else starts
those workflows: not a push to `main`, not a pull request, not a tag on its
own. To cut a release:

```sh
git tag 0.2.0
git push origin 0.2.0         # the tag has to reach the remote
git push origin HEAD:releases # this is what triggers the three workflows
```

The commit that lands on `releases` **must carry a tag**, and that tag names
the release. If no tag points at that exact commit the run stops with an error
rather than publish — a release labelled `0.2.0` but built from something that
is not `0.2.0` cannot be taken back once people have downloaded it. Pushing
the same tag to `releases` again replaces that release's files.

Note the consequence of `releases` being the only trigger: a packaging
regression is discovered when you try to publish, not before. If that becomes
annoying, the fix is a build-only run on `main` — the same jobs minus
`release`.

The three workflows publish **independently**: each attaches its file as soon
as it is ready, so a build broken on one platform does not hold up the other
two. The price is that a release can be incomplete with nothing saying so, so
check that all three ran green before announcing a version. Their release jobs
share one `concurrency` group, which is what stops them racing to create the
same release — a concurrency group is repository-wide, not workflow-scoped. The macOS image is the one still built by hand, since GitHub's macOS
runners cannot notarise on their own and the image needs a Mac anyway.

The Windows script is PowerShell rather than bash: it drives Windows tools
(`ISCC.exe`, `signtool.exe`), and PowerShell is on every Windows machine while
bash is not.

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

`.github/workflows/rpm.yml` builds it in a `fedora:latest` container
on an Ubuntu runner (`build-rpm`), then installs it in a *clean* container of
the same image to check it (`verify-rpm`) — clean because the build container
has every `-devel` package installed and would satisfy the runtime
requirements by accident.

Two things worth knowing about that job. It has opam **build its own
compiler** rather than reuse Fedora's through `ocaml-system`. That is not the
cheaper option — it costs a few minutes whenever the cache is cold — but
Fedora splits the OCaml compiler across several RPMs, and `compiler-libs`
(`Toploop`, `Topdirs`, `compiler-libs.bytecomp`) is one of the pieces that is
not pulled in by the `ocaml` package: against `ocaml-system`, `ocamlfind`,
`stdlib-shims` and `ocaml-compiler-libs` all fail to build for want of exactly
those modules. Installing the missing RPM fixes that one instance; building the
compiler removes the class of mismatch. The switch is a named one inside
`~/.opam` rather than a local `./_opam`, so that the cache step actually covers
it — a local switch sits in the workspace, outside the cached path, and would
be rebuilt every run.

And the container image decides the package's glibc floor, so whichever Fedora
it builds in is the oldest one the RPM will install on — the comment above the
`image:` key explains why it is not pinned to an older release the way the
Debian build is.


# Windows — `make-installer.ps1`

`make-installer.ps1` builds an Inno Setup installer:
`dist\Sun-notes-<version>-<arch>-setup.exe`.

```powershell
.\packaging\make-installer.ps1 -Release      # what you hand to someone else
.\packaging\make-installer.ps1               # dev profile, for a quick check
```

| Option | |
|---|---|
| `-Release` | Build with dune's `release` profile. Without it, the `dev` profile is packaged as is. |
| `-Version X.Y.Z` | Installer version. Defaults to the nearest git tag, then to `0.1.0`. |
| `-OutDir DIR` | Where to write the installer. Defaults to `dist\`. |
| `-NoBuild` | Package whatever is already in `_build\`. |
| `-KeepTree` | Also leave the staged payload and the generated `.iss` next to the installer. |
| `-SignToolPath PATH`, `-SignArgs "..."` | Sign the finished installer with your own certificate. |

Requirements: Windows, the project's opam switch, and **Inno Setup 6.3 or
later** (`winget install JRSoftware.InnoSetup`). ImageMagick or Pillow is
needed to turn `logo.png` into an `.ico` — that one is not optional, since
Inno wants an icon. `rcedit` and `objdump`/`dumpbin` are used if present; the
script says what it loses without them.

Remember that owebview needs the WebView2 SDK headers at *build* time, through
NuGet — `nuget install Microsoft.Web.WebView2` before `opam install .`, as the
main README says.

## The three things Windows changes

**Nothing resolves dependencies at install time.** There is no apt or dnf, so
any DLL the executable imports and Windows does not ship has to travel inside
the installer. The script reads the import table with `objdump` or `dumpbin`,
filters out the DLLs Windows provides, hunts for the rest on `PATH`, copies
them into the payload, and refuses to build if one cannot be found. Where the
`.deb` *declares* and the `.rpm` *infers*, this one *carries*.

It walks the **whole import closure**, not just the executable's own table,
and that distinction is not academic: it is what 0.1.0 got wrong. `main.exe`
imports `libstdc++-6.dll`, which in turn imports `libgcc_s_seh-1.dll` and
`libwinpthread-1.dll` — neither of which appears anywhere in `main.exe`'s
imports. Scanning one level deep bundled `libstdc++-6.dll` alone, and the
installed app died on launch with *"the code execution cannot proceed because
libgcc_s_seh-1.dll was not found"* on every machine without a toolchain. The
script now queues each DLL it bundles and scans that one too, until nothing
new turns up.

In practice what it would carry is the mingw-w64 runtime. owebview's Windows
target is mingw only — its `lib/config/discover.ml` matches on `"mingw64"` and
has no MSVC branch — and its link flags include `-lstdc++`, which brings in
`libstdc++-6.dll` and, with it, `libgcc_s_seh-1.dll` and `libwinpthread-1.dll`.

owebview's `mingw_link_flags` now carries `-static-libgcc
-static-libstdc++`, which folds the GCC runtime into the executable — but
**that is not in effect here yet**, and will not be until it is released.
`opam install . --deps-only` resolves `owebview` from the opam repository, and
the published 0.1.0 predates the change; a local edit to a sibling checkout
changes nothing for this project or for CI. So expect the three DLLs to be
bundled until owebview is republished and this project's dependency moves with
it.

There is a second caveat for when it does land, written out in full in the
comment beside those flags: `-static-libstdc++` is implemented by the *g++*
driver, which swaps out the `-lstdc++` it adds itself, whereas OCaml links
through the C driver against an explicit `-lstdc++` — so it may be a no-op,
and only a Windows build settles it. `-static-libgcc` is handled by the common
driver and does take effect.

Either way this script is where you find out: the "bundling" lines of step 3
name every DLL that goes in.

`WebView2Loader.dll` is *not* one of them, which is worth stating because it
is the natural assumption. owebview's vendored `webview.h` defaults to
`WEBVIEW_MSWEBVIEW2_BUILTIN_IMPL=1`: it finds the runtime through the registry
itself, and the `LoadLibraryW` of `WebView2Loader.dll` is guarded by an
`is_loaded()` check with the built-in implementation as the fallback. Loaded
by name at runtime, it never appears in the import table, and it is never
required.

**WebView2 may be missing.** It ships with Windows 11 and reaches most
Windows 10 machines through Edge, but "most" is not "all", and when it is
absent the app starts and shows an empty window — no error, nothing to
diagnose. The installer therefore looks for the runtime and, if it is not
there, downloads Microsoft's Evergreen bootstrapper and runs it before the app.
A failed download is not fatal: it explains the situation and carries on,
because refusing to install helps nobody.

The registry checks deliberately mirror the ones the app will make at startup:
`webview.h`'s `find_installed_client` reads the `EBWebView` value under
`SOFTWARE\Microsoft\EdgeUpdate\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`
in the 32-bit registry view, per-machine first and then per-user. Checking the
same places is what stops the installer from ever reporting success where the
app would then show an empty window. Microsoft's documented
`Clients\<guid>\pv` value is consulted too, as a second opinion.

**The executable has no icon.** `main.ml` never calls `set_app_icon`, and on
Windows that call only sets the *window* icon anyway — what Explorer and the
Start menu show comes from an ICO resource compiled into the `.exe`. The script
embeds one with `rcedit` when it is available, and installs a `.ico` that the
shortcuts point at regardless, so the shortcuts look right either way. Without
`rcedit` the file itself keeps the generic icon in Explorer.

## Install scope and signing

The installer asks for `PrivilegesRequired=lowest`, so a normal install needs
no UAC prompt and lands under the user's own profile; the wizard still offers
to elevate for an all-users install. `ArchitecturesAllowed=x64compatible`
means the x64 build also installs on Windows on ARM, which runs it under
emulation.

It is **not signed** unless you pass `-SignToolPath`. An unsigned installer
makes SmartScreen tell the user the publisher is unknown, and that warning
persists until the certificate accumulates reputation — the Windows equivalent
of the notarisation problem described in the macOS section above, and rather
more expensive to solve, since a code-signing certificate is an annual cost.

## Publishing it

`.github/workflows/windows.yml` builds it on a `windows-latest` runner
(`build-windows`), then installs it silently on a second, clean runner to check
it (`verify-windows`).

Two ordering details in that job are not obvious. The WebView2 SDK headers have
to be fetched **before `opam install`**, not before the packaging script:
owebview is a dependency, so its `discover.ml` runs — and needs `WebView2.h` —
during the dependency install. And the job sets `MICROSOFT_WEB_WEBVIEW2`
explicitly rather than relying on `discover.ml`'s NuGet-cache search, because
`nuget install` unpacks into the working directory rather than into
`%USERPROFILE%\.nuget\packages`.

Inno Setup is `choco upgrade`d rather than assumed: the runner image carries a
version of its own, and it may predate the 6.3 this script needs.

The install check pins `/DIR=C:\sun-notes-test` so it does not have to guess
where `PrivilegesRequired=lowest` put the files.

Then it launches the app **with `PATH` stripped to the system directories**.
That is the check that would have caught the 0.1.0 bug and did not exist at
the time: a runner has the mingw toolchain on its `PATH`, so the app started
there quite happily while the installer it had just built was missing a DLL.
With `PATH` reduced, Windows can only resolve DLLs from the install directory,
exactly as on a user's machine. The assertion is on the webview version line,
which `main.ml` prints *before* creating any window — reaching it proves every
DLL resolved. Whether the window then opens is checked separately and
advisorily, since that depends on the runner having a desktop session.

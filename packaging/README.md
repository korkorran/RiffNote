# Packaging

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

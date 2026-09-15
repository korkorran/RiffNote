<p align="center">
  <img src="./logo.png" width="200" alt="sun-notes">
</p>
<h1 align=center>Sun notes</h1>
<p align="center">A note-taking app written in OCaml</p>
<br/>

Implemented with the libraries Owebview for the desktop-GUI bindings and Vdom for the web rendering.

![Screenshot of Sun notes](./screenshot.jpg)

## Download

Click on the "Releases" link of the Github page of the repository to access the installers.

| Platform | File | Notes |
|---|---|---|
| macOS, Apple Silicon | `.dmg` | macOS 11 or later. The app is signed ad-hoc but not notarised: on first launch, right-click it in Applications and choose *Open*. |
| Debian, Ubuntu and derivatives (x86-64) | `.deb` | Debian 12 / Ubuntu 22.04 or later, which is where webkit2gtk-4.1 arrives. Install with `sudo apt install ./sun-notes_<version>_amd64.deb`. |

Intel Macs, Windows and other Linux distributions are not built yet; see
[packaging/](./packaging) to build from source.

## Contribute

Clone the repository.

All the dependencies can be installed with the command

```sh
opam install . --deps-only
```
The project depends on owebview so on Windows, prior to 'opam install .', run the command `nuget install Microsoft.Web.WebView2` to install the WebView2 SDK.

To run the app :

```sh
dune build
dune exec run/main.exe
```

## License

MIT
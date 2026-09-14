# Sun notes

A note-taking app written in OCaml

## Setup

Requires [opam](https://opam.ocaml.org/doc/Install.html).

Create a local switch (a `_opam` directory at the root of the project) with the
latest OCaml compiler:

```sh
opam switch create . ocaml-base-compiler.5.5.1 --no-install
```

Install the dependencies:

```sh
opam install brr owebview.0.1.0 vdom
```

Then load the switch environment in your shell:

```sh
eval $(opam env)
```

`opam` picks up the local switch automatically when you run commands from the
project directory, so `opam exec -- dune build` works without the `eval` step.

### Native dependencies

`owebview` binds the system web engine: nothing to install on macOS (WebKit and
Cocoa ship with the system) or Windows (the WebView2 runtime ships with Windows
10 and 11). On Linux, opam pulls in `conf-gtk3-webkit`, which expects
`gtk+-3.0` and `webkit2gtk-4.1` to be available through your package manager.

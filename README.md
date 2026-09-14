# Sun notes

A note-taking app written in OCaml

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
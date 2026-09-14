(lang dune 3.24)

(generate_opam_files true)

(name sun-notes)
(source
 (github korkorran/Sun-notes))
(license MIT)
(authors "Frédéric Lang")
(maintainers "frederic.ln.lang@gmail.com")

(package
 (name sun-notes)
 ; Nothing is installed into the switch: the executable finds its web/ assets
 ; next to itself in the build tree (see the alias in run/dune), so giving it a
 ; public_name would install a binary whose page is missing. The package exists
 ; for the metadata and for `opam install . --deps-only`.
 (allow_empty)
 (synopsis "A note-taking app written in OCaml")
 (description
  "A desktop note-taking application written entirely in OCaml, both sides of\nit. The window is a native one rendered by the system web engine through\nowebview; the page inside it is OCaml too, compiled to JavaScript with\njs_of_ocaml and driven by ocaml-vdom in the Elm style, so the whole interface\nis a pure function of a model.\n\nBrowse a directory as a tree, open several files at once as tabs, edit them\nand write them back. The two panes are self-contained vdom components that\nspeak only through their own message types.\n\nThe native side answers the page over the webview bridge, and does so on an\nLwt event loop of its own rather than on the UI thread: a slow disk, a network\nmount or a large file cannot freeze the window, and several calls interleave\ninstead of queuing behind each other.")
 (tags
  ("notes" "editor" "desktop" "webview" "gui" "js_of_ocaml"))
 (depends
  ; 4.14 is where In_channel and Out_channel arrived, which the bindings use
  ; to read and write files.
  (ocaml
   (>= 4.14))
  (owebview
   (>= 0.1.0))
  ; The page: brr for the bridge to the bindings, vdom for the DOM.
  brr
  vdom
  ; 5.3 is where Lwt.Syntax arrived, which binding.ml opens for let*.
  (lwt
   (>= 5.3))
  ; (modes js) in run/web/dune compiles the page to JavaScript.
  js_of_ocaml-compiler))

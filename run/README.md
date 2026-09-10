# Full OCaml application

Ocaml is able to compile to javascript using [js_of_ocaml](https://github.com/ocsigen/js_of_ocaml/). This can be automated in dune by adding [(modes js)](https://dune.readthedocs.io/en/stable/jsoo.html) in the executable rule.


In the example, we are using [Brr](https://erratique.ch/software/brr) for the interaction with the webview API, and [ocaml-vdom](https://github.com/LexiFi/ocaml-vdom) to drive the UI. The two never exchange values: `Jv` only crosses the bridge to the native side, while the DOM belongs entirely to vdom (through the `Js_browser` module it ships with).

## An Elm-style UI

`index.html` contains nothing but a mount point:

```html
<div id="app"></div>
```

Everything the user sees comes from a `view` function, and every interaction —
a click, but also a message pushed by the native side — goes through a single
`update`. No DOM node is looked up or mutated by hand.

```
type model = { output : string; pending : bool }

type msg =
  | Add_clicked
  | Os_clicked
  | Added of string
  | Os_answered
  | Pushed of string
  | Failed of string
```

Holding the UI state in a record rather than in the DOM buys things that are
awkward with event listeners. `pending` is the obvious one: both buttons are
disabled while a call is in flight, and that falls out of the model instead of
needing a flag on the side.

```
let view { output; pending } =
  let open Vdom in
  div
    [ elt "h2" [ text "owebview" ];
      div ~a:[ class_ "actions" ]
        [ elt "button" ~a:[ onclick (fun _ -> Add_clicked); disabled pending ]
            [ text "add(20, 22)" ] ];
      elt "pre" ~a:[ attr "id" "out" ] [ text output ] ]
```

The application is instantiated once the page is ready:

```
let running = Vdom_blit.run ~env:webview_cmds ~container app
```

## Calling a binding

A binding answers with a promise, so calling one is asynchronous. It is
therefore expressed as a *command* rather than run from `update` — that keeps
`update` a pure function of the model and confines the JavaScript call to one
handler. `Vdom.Cmd.t` is an open type, meant to be extended this way:

```
type 'msg Vdom.Cmd.t +=
  | Call of string * Jv.t array * (string -> 'msg) * (string -> 'msg)

let webview_cmds =
  Vdom_blit.cmd
    { Vdom_blit.Cmd.f =
        (fun ctx cmd ->
          match cmd with
          | Call (name, args, on_ok, on_error) ->
              call name args
                ~ok:(fun s -> Vdom_blit.Cmd.send_msg ctx (on_ok s))
                ~error:(fun s -> Vdom_blit.Cmd.send_msg ctx (on_error s));
              true
          | _ -> false) }
```

`update` then only names the message it expects back:

```
| Add_clicked ->
    Vdom.return
      ~c:[ Call ("add", [| Jv.of_int 20; Jv.of_int 22 |],
                 (fun sum -> Added sum), fun e -> Failed e) ]
      { model with pending = true }
```

The call itself is the one piece of raw interop left. Note that the resolved
value is stringified in JavaScript: `add` resolves with a number and `os_type`
with a string, so neither shape can be assumed.

```
(** Call the binding in the application, then reports its outcome *)
let call : string -> Jv.t array -> ok:(string -> unit) -> error:(string -> unit) -> unit =
 fun name args ~ok ~error ->
  let to_string v = Jv.to_string (Jv.call Jv.global "String" [| v |]) in
  let promise = Jv.call Jv.global name args in
  let _ =
    Jv.Promise.then' promise
      (fun v -> ok (to_string v); Jv.null)
      (fun e -> error (to_string e); Jv.null)
  in
  ()
```

(In a general way, the OCaml code will be more verbose than the same code in pure javascript)

The example also show how to declare a function and to call it directly using `Webview.eval`.

```
(** Register the function in the global object in order to use it from the main
    application *)
let register : string -> 'a -> unit =
 fun name f -> Jv.set Jv.global name (Jv.repr f)
```

## From the terminal to the page

The example also goes the other way round: anything typed in the terminal is
pushed to the page and rendered in the output pane. It reuses the `show`
function that `app.ml` registered on the global object, so no extra binding is
needed on the JS side.

```
let line = input_line stdin in
let js =
  Printf.sprintf "if (typeof show === 'function') show(%s);" (Utils.js_quote line)
in
Webview.dispatch w (fun w -> Webview.eval w js)
```

On the page side, `show` does not touch the DOM either — it injects a message,
so text arriving from the native side follows exactly the same path as a click:

```
register "show" (fun (s : Jstr.t) ->
    Vdom_blit.process running (Pushed (Jstr.to_string s)))
```

This is also how the `os_type` binding answers: it evaluates `show(...)` instead
of returning a result, which is why its message is called `Os_answered` and
carries nothing.

Two things are worth noting on the native side.

`input_line` blocks, so the loop runs on its own thread (hence `threads.posix`
in the `dune` file). A webview may only be touched from the thread that called
`Webview.run`, so the evaluation is handed over with `Webview.dispatch` rather
than calling `Webview.eval` directly from the reader thread.

The message is interpolated into JavaScript source, so it has to be quoted as a
JS literal. `Printf`'s `%S` looks like the obvious tool but is the wrong one: it
escapes bytes above 127 as a decimal `\ddd`, which JavaScript reads as a legacy
*octal* escape, so any accented or emoji input reaches the page mangled.
`Utils.js_quote` passes UTF-8 bytes through untouched and escapes only what
would close the literal or break the line.

(* The bridge to the native side. main.ml registers its bindings as functions
   on the JavaScript global object, and every one of them answers with a
   promise; this module is the single place that knows it.

   Widgets do not call a binding themselves: they return [Call] as a command,
   and [env] below is what actually performs it and feeds the answer back as a
   message. That keeps their [update] a pure function of their model. *)

(** Print a resolved value: the bindings answer with whatever JSON their OCaml
    side returned — a number for [add], a string for [read_file] — and
    [String(v)] copes with all of them. *)
let to_string v = Jv.to_string (Jv.call Jv.global "String" [| v |])

(** Call a binding registered with [Webview.bind]. The resolved value is handed
    to [ok] untouched rather than stringified, because [read_dir] answers with
    an array of objects that only survives as a JavaScript value. *)
let call : string -> Jv.t array -> ok:(Jv.t -> unit) -> error:(string -> unit) -> unit
    =
 fun name args ~ok ~error ->
  let promise = Jv.call Jv.global name args in
  let _ =
    Jv.Promise.then' promise
      (fun v ->
        ok v;
        Jv.null)
      (fun e ->
        error (to_string e);
        Jv.null)
  in
  ()

(** Register a function on the global object, so that the native side can call
    into the page the same way the page calls into it. *)
let register : string -> 'a -> unit =
 fun name f -> Jv.set Jv.global name (Jv.repr f)

(* Calling a binding is asynchronous, so it is expressed as a command instead
   of being run from an [update]. [Vdom.Cmd.t] is an open type, meant to be
   extended this way. *)
type 'msg Vdom.Cmd.t +=
  | Call of string * Jv.t array * (Jv.t -> 'msg) * (string -> 'msg)

(** The command handler to hand to [Vdom_blit.run ~env]. Without it a [Call]
    would simply be ignored. *)
let env =
  Vdom_blit.cmd
    {
      Vdom_blit.Cmd.f =
        (fun ctx cmd ->
          match cmd with
          | Call (name, args, on_ok, on_error) ->
              call name args
                ~ok:(fun v -> Vdom_blit.Cmd.send_msg ctx (on_ok v))
                ~error:(fun s -> Vdom_blit.Cmd.send_msg ctx (on_error s));
              true
          | _ -> false);
    }

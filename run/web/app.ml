(* Elm-style application: the UI is a pure function of a model, and every
   interaction goes through a message. Nothing here looks up or mutates a DOM
   node by hand — [Vdom_blit] diffs the tree returned by [view] and patches the
   document itself.

   Two JavaScript worlds meet in this file:
   - [Js_browser] (shipped with vdom) for the DOM: the mount point and the
     page-ready event;
   - [Jv] (brr) for the bindings that hellowv.ml exposes on the global object.
     They never exchange values, so the two stay side by side. *)

(** Call a binding registered with [Webview.bind]. It answers with a promise
    resolving to the JSON value the OCaml side returned. *)
let call : string -> Jv.t array -> ok:(string -> unit) -> error:(string -> unit) -> unit =
 fun name args ~ok ~error ->
  (* [add] resolves with a number and [os_type] with a string, so the value is
     stringified in JavaScript rather than assumed to be one shape or the
     other. *)
  let to_string v = Jv.to_string (Jv.call Jv.global "String" [| v |]) in
  let promise = Jv.call Jv.global name args in
  let _ =
    Jv.Promise.then' promise
      (fun v ->
        ok (to_string v);
        Jv.null)
      (fun e ->
        error (to_string e);
        Jv.null)
  in
  ()

(** Register the function in the global object in order to use it from the main
    application *)
let register : string -> 'a -> unit =
 fun name f -> Jv.set Jv.global name (Jv.repr f)

(** The whole state of the UI. *)
type model = {
  output : string;  (** what the output pane displays *)
  pending : bool;  (** a binding call is in flight *)
}

type msg =
  | Add_clicked
  | Os_clicked
  | Added of string  (** [add] resolved with its sum *)
  | Os_answered
      (** [os_type] resolved; the text itself reaches us through [show], since
          that binding answers by evaluating JavaScript rather than by
          returning a result *)
  | Pushed of string  (** the native side called [show] *)
  | Failed of string

(* Calling a binding is asynchronous, so it is expressed as a command instead
   of being run from [update]: that keeps [update] a pure function of the model
   and confines the JavaScript call to the handler below. [Vdom.Cmd.t] is an
   open type, meant to be extended this way. *)
type 'msg Vdom.Cmd.t +=
  | Call of string * Jv.t array * (string -> 'msg) * (string -> 'msg)

let webview_cmds =
  Vdom_blit.cmd
    {
      Vdom_blit.Cmd.f =
        (fun ctx cmd ->
          match cmd with
          | Call (name, args, on_ok, on_error) ->
              call name args
                ~ok:(fun s -> Vdom_blit.Cmd.send_msg ctx (on_ok s))
                ~error:(fun s -> Vdom_blit.Cmd.send_msg ctx (on_error s));
              true
          | _ -> false);
    }

let init = Vdom.return { output = ""; pending = false }

let update model = function
  | Add_clicked ->
      Vdom.return
        ~c:
          [
            Call
              ( "add",
                [| Jv.of_int 20; Jv.of_int 22 |],
                (fun sum -> Added sum),
                fun e -> Failed e );
          ]
        { model with pending = true }
  | Os_clicked ->
      Vdom.return
        ~c:[ Call ("os_type", [||], (fun _ -> Os_answered), fun e -> Failed e) ]
        { model with pending = true }
  | Added sum -> Vdom.return { output = sum; pending = false }
  | Os_answered -> Vdom.return { model with pending = false }
  | Pushed text -> Vdom.return { model with output = text }
  | Failed e -> Vdom.return { output = "error: " ^ e; pending = false }

let view { output; pending } =
  let open Vdom in
  div
    [
      elt "h2" [ text "owebview" ];
      div
        ~a:[ class_ "actions" ]
        [
          elt "button"
            ~a:[ onclick (fun _ -> Add_clicked); disabled pending ]
            [ text "add(20, 22)" ];
          elt "button"
            ~a:[ onclick (fun _ -> Os_clicked); disabled pending ]
            [ text "OS type" ];
        ];
      (* The id is kept so the rules of style.css still apply. *)
      elt "pre" ~a:[ attr "id" "out" ] [ text output ];
    ]

let app = Vdom.app ~init ~update ~view ()

let run () =
  (* This code is executed once the view is initialized, the elements are all
  ready *)
  let container =
    Option.get (Js_browser.Document.get_element_by_id Js_browser.document "app")
  in
  let running = Vdom_blit.run ~env:webview_cmds ~container app in
  (* hellowv.ml evaluates show("...") both to forward a line typed in the
     terminal and to answer the os_type binding. Injecting it as a message
     keeps that path identical to a click: the view stays the only thing that
     touches the DOM. *)
  register "show" (fun (s : Jstr.t) ->
      Vdom_blit.process running (Pushed (Jstr.to_string s)))

let () =
  Js_browser.Window.add_event_listener Js_browser.window
    Js_browser.Event.DOMContentLoaded
    (fun _ -> run ())
    false

(* The paste shortcut in a text field.

   The window carries no menu bar, and on macOS that is exactly where the
   standard editing key equivalents live: with no Edit menu holding a Paste
   item, the system never turns Cmd+V into a paste, and the only way in is the
   web engine's own context menu. The keystroke does reach the page as an
   ordinary keydown though, so the shortcut can be served here instead — the
   page reads the clipboard itself and splices the text in.

   This is a shim for a platform behaviour that is missing, not application
   logic, which is why it sits apart from the widgets that use it. *)

open Vdom

(* Reading the clipboard is asynchronous, so it is a command, like every other
   answer the page cannot produce on the spot. *)
type 'msg Vdom.Cmd.t += Read of (string -> 'msg)

(** Read the clipboard and hand its text to [k]. *)
let read k = Read k

(** The command handler to merge into the one given to [Vdom_blit.run ~env]. *)
let env =
  Vdom_blit.cmd
    {
      Vdom_blit.Cmd.f =
        (fun ctx cmd ->
          match cmd with
          | Read k ->
              let clipboard =
                Jv.get (Jv.get Jv.global "navigator") "clipboard"
              in
              let _ =
                Jv.Promise.then'
                  (Jv.call clipboard "readText" [||])
                  (fun text ->
                    Vdom_blit.Cmd.send_msg ctx (k (Jv.to_string text));
                    Jv.null)
                  (* Nothing readable means nothing to paste. Someone who
                     pressed a shortcut has no use for an error about it. *)
                  (fun _ -> Jv.null)
              in
              true
          | _ -> false);
    }

(** Fire [f start stop] when the paste shortcut is pressed in a text field,
    where [start] and [stop] delimit the selection the pasted text replaces —
    the same pair a real paste event would carry.

    The default is prevented for that combination only, so every other
    keystroke reaches the field untouched. *)
let on_shortcut f =
  on_with_options "keydown"
    Decoder.(
      let+ key = field "key" string
      and+ code = field "code" string
      and+ meta = field "metaKey" bool
      and+ ctrl = field "ctrlKey" bool
      and+ start = field "target.selectionStart" int
      and+ stop = field "target.selectionEnd" int in
      (* [code] names the physical key, so the shortcut still lands on a layout
         that does not put V where QWERTY does; [key] covers the case of a
         remapped keyboard where it does not. *)
      if (meta || ctrl) && (key = "v" || key = "V" || code = "KeyV") then
        {
          msg = Some (f start stop);
          stop_propagation = false;
          prevent_default = true;
        }
      else { msg = None; stop_propagation = false; prevent_default = false })

(* Elm-style application: the UI is a pure function of a model, and every
   interaction goes through a message. Nothing here looks up or mutates a DOM
   node by hand — [Vdom_blit] diffs the tree returned by [view] and patches the
   document itself.

   This file is only the assembly. The two panes are components of their own —
   [FileExplorer] on the left, [ContentEditor] on the right — each with its own
   model, messages and update. All that is left here is holding one of each,
   forwarding messages to the right one, and carrying across the single thing
   they have to say to each other: the explorer opened a file, the editor shows
   it. *)

type msg =
  | Explorer_msg of FileExplorer.msg
  | Editor_msg of ContentEditor.msg

type model = {
  explorer : FileExplorer.model;
  editor : ContentEditor.model;
}

let init =
  let explorer, cmd = FileExplorer.init in
  ( { explorer; editor = ContentEditor.init },
    Vdom.Cmd.map (fun m -> Explorer_msg m) cmd )

(** Act on what the explorer reported. This is the whole of the coupling
    between the two panes. *)
let apply_out model = function
  | FileExplorer.File_opened (path, contents) ->
      { model with editor = ContentEditor.open_file model.editor ~path ~contents }
  | FileExplorer.File_created path ->
      { model with editor = ContentEditor.open_new_file model.editor ~path }

(* Each pane runs its own update; whatever it produces comes back wrapped, so
   the message types never mix. *)
let update model = function
  | Explorer_msg m ->
      let explorer, cmd, out = FileExplorer.update model.explorer m in
      ( List.fold_left apply_out { model with explorer } out,
        Vdom.Cmd.map (fun m -> Explorer_msg m) cmd )
  | Editor_msg m ->
      let editor, cmd = ContentEditor.update model.editor m in
      ({ model with editor }, Vdom.Cmd.map (fun m -> Editor_msg m) cmd)

let view { explorer; editor } =
  let open Vdom in
  div
    ~a:[ class_ "layout" ]
    [
      div
        ~a:[ class_ "controls" ]
        [ map (fun m -> Explorer_msg m) (FileExplorer.view explorer) ];
      (* The id is kept so the rules of style.css still apply. *)
      div
        ~a:[ attr "id" "out" ]
        ((* A read in flight is announced above the editor rather than in place
            of it: replacing the pane would take the tab strip away with it. *)
         (if FileExplorer.is_reading explorer then
            [ elt "p" ~a:[ class_ "status" ] [ text "reading\xe2\x80\xa6" ] ]
          else [])
        @ [ map (fun m -> Editor_msg m) (ContentEditor.view editor) ]);
    ]

let app = Vdom.app ~init ~update ~view ()

let run () =
  (* This code is executed once the view is initialized, the elements are all
  ready *)
  let container =
    Option.get (Js_browser.Document.get_element_by_id Js_browser.document "app")
  in
  ignore (Vdom_blit.run ~env:Binding.env ~container app)

let () =
  Js_browser.Window.add_event_listener Js_browser.window
    Js_browser.Event.DOMContentLoaded
    (fun _ -> run ())
    false

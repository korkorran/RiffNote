(* The content pane, as a self-contained vdom component: its own model, its own
   messages, its own update, and no knowledge of the application around it.
   app.ml embeds it with [Vdom.map] and [Vdom.Cmd.map], which is how ocaml-vdom
   nests a child into a parent — the child speaks its own message type and the
   parent wraps it on the way up. *)

open Vdom

type msg =
  | UpdateContent of string
  | ToggleMode of bool
  | SaveFile of string
  | Save_done of string  (** [write_file] answered, with the byte count *)
  | Save_failed of string

(** Where the last save got to. It is reported next to the button rather than
    silently: a save that failed and a save that never happened look the same
    otherwise. *)
type status =
  | Idle
  | Saving
  | Saved of string  (** how many bytes reached the disk *)
  | Failed of string

type model = {
  content : string;  (** what the pane shows, and what [SaveFile] would write *)
  editable_markdown : bool;  (** render the content as markdown once editable *)
  editable_mode : bool;  (** the pane is an editor rather than a viewer *)
  file_path : string;  (** the file the content came from; "" when none *)
  status : status;  (** what became of the last save *)
}

let init =
  {
    content = "";
    editable_markdown = false;
    editable_mode = false;
    file_path = "";
    status = Idle;
  }

(** Replace what the pane shows. The application calls this when a file has
    just been read, or when the native side pushes a line — neither is a user
    edit, so neither goes through [update]. *)
let set_content model content = { model with content; status = Idle }

(** Point the pane at another file, so that [SaveFile] carries the right path. *)
let set_file_path model file_path = { model with file_path; status = Idle }

let write_file path contents =
  Binding.Call
    ( "write_file",
      [| Jv.of_string path; Jv.of_string contents |],
      (fun written -> Save_done (Binding.to_string written)),
      fun e -> Save_failed e )

let update model = function
  (* Editing invalidates whatever the last save said: the file on disk no
     longer holds what the pane is showing. *)
  | UpdateContent content -> return { model with content; status = Idle }
  | ToggleMode editable_mode -> return { model with editable_mode }
  | SaveFile path ->
      return
        ~c:[ write_file path model.content ]
        { model with status = Saving }
  | Save_done written -> return { model with status = Saved written }
  | Save_failed e -> return { model with status = Failed e }

let status_view = function
  | Idle -> []
  | Saving -> [ elt "span" ~a:[ class_ "status" ] [ text "saving\xe2\x80\xa6" ] ]
  | Saved written ->
      [ elt "span" ~a:[ class_ "status" ] [ text (written ^ " bytes written") ] ]
  | Failed e ->
      [ elt "span" ~a:[ class_ "status error" ] [ text ("error: " ^ e) ] ]

let view model =
  let content =
    if model.editable_mode then
      (* A textarea, not an input: the pane holds whole files, which an input
         would collapse onto a single line. *)
      elt "textarea"
        ~a:
          [
            class_ "editor-content";
            value model.content;
            oninput (fun s -> UpdateContent s);
          ]
        []
    else elt "pre" ~a:[ class_ "editor-content" ] [ text model.content ]
  in
  div
    ~a:[ class_ "editor" ]
    [
      div
        ~a:[ class_ "editor-toolbar" ]
        ([
          elt "button"
            ~a:[ onclick (fun _ -> ToggleMode (not model.editable_mode)) ]
            [ text (if model.editable_mode then "view" else "edit") ];
          elt "button"
            ~a:
              [
                onclick (fun _ -> SaveFile model.file_path);
                disabled (model.file_path = "" || model.status = Saving);
              ]
            [ text "save" ];
        ]
        @ status_view model.status);
      content;
    ]

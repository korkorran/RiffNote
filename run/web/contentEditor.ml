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

type model = {
  content : string;  (** what the pane shows, and what [SaveFile] would write *)
  editable_markdown : bool;  (** render the content as markdown once editable *)
  editable_mode : bool;  (** the pane is an editor rather than a viewer *)
  file_path : string;  (** the file the content came from; "" when none *)
}

let init =
  {
    content = "";
    editable_markdown = false;
    editable_mode = false;
    file_path = "";
  }

(** Replace what the pane shows. The application calls this when a file has
    just been read, or when the native side pushes a line — neither is a user
    edit, so neither goes through [update]. *)
let set_content model content = { model with content }

(** Point the pane at another file, so that [SaveFile] carries the right path. *)
let set_file_path model file_path = { model with file_path }

let update model = function
  | UpdateContent content -> return { model with content }
  | ToggleMode editable_mode -> return { model with editable_mode }
  | SaveFile _path ->
      (* The native side exposes no write_file binding yet, so saving is still
         a no-op; the message exists so that the button is already wired. *)
      return model

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
        [
          elt "button"
            ~a:[ onclick (fun _ -> ToggleMode (not model.editable_mode)) ]
            [ text (if model.editable_mode then "view" else "edit") ];
          elt "button"
            ~a:
              [
                onclick (fun _ -> SaveFile model.file_path);
                disabled (model.file_path = "");
              ]
            [ text "save" ];
        ];
      content;
    ]

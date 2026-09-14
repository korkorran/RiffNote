(* The content pane, as a self-contained vdom component: its own model, its own
   messages, its own update, and no knowledge of the application around it.
   app.ml embeds it with [Vdom.map] and [Vdom.Cmd.map], which is how ocaml-vdom
   nests a child into a parent — the child speaks its own message type and the
   parent wraps it on the way up.

   It holds several files at once. Each one is a [tab] carrying its own
   contents, its own view/edit mode and its own save status; the strip along
   the top switches between them. Nothing is shared between two tabs, so a save
   in flight on one cannot land on another. *)

open Vdom

type msg =
  | UpdateContent of string  (** the active tab was typed into *)
  | ToggleMode of bool
  | SaveFile of string  (** path *)
  | Save_done of string * string * string  (** path, contents, byte count *)
  | Save_failed of string * string
  | Tab_selected of string
  | Close_requested of string
  | Close_confirmed of string
  | Close_cancelled of string

(** Where the last save of one tab got to. It is reported next to the button
    rather than silently: a save that failed and a save that never happened
    look the same otherwise. *)
type status =
  | Idle
  | Saving
  | Saved of string  (** how many bytes reached the disk *)
  | Failed of string

(** One open file. [saved_content] is what the disk last held, so that being
    modified is a fact about two strings rather than a flag to keep in step by
    hand. *)
type tab = {
  path : string;
  content : string;  (** what the pane shows, and what a save would write *)
  saved_content : string;  (** what was last read from, or written to, disk *)
  editable_markdown : bool;  (** render the content as markdown once editable *)
  editable_mode : bool;  (** this tab is an editor rather than a viewer *)
  status : status;
  closing : bool;  (** a close waiting to be confirmed, the tab being modified *)
}

type model = {
  tabs : tab list;
  active : string option;  (** path of the tab on display *)
}

let init = { tabs = []; active = None }

let is_modified tab = tab.content <> tab.saved_content
let find_tab model path = List.find_opt (fun tab -> tab.path = path) model.tabs

let active_tab model =
  match model.active with None -> None | Some path -> find_tab model path

(** Apply [f] to the tab at [path], leaving every other one alone. *)
let set_tab path f tabs =
  List.map (fun tab -> if tab.path = path then f tab else tab) tabs

(** Show [path]. A file that is already open is only brought to the front:
    reading it again would throw away whatever has been typed into it since,
    which is not what clicking a name in the tree asks for. *)
let open_file model ~path ~contents =
  let model = { model with active = Some path } in
  if List.exists (fun tab -> tab.path = path) model.tabs then model
  else
    let tab =
      {
        path;
        content = contents;
        saved_content = contents;
        editable_markdown = false;
        editable_mode = false;
        status = Idle;
        closing = false;
      }
    in
    (* Appended rather than prepended: a new tab belongs at the end of the
       strip, where the eye last left it. *)
    { model with tabs = model.tabs @ [ tab ] }

(** Drop the tab at [path]. What takes its place is the tab on its right, or
    failing that the one on its left — closing the last tab of a strip should
    not land on the far end of it. *)
let close_tab model path =
  let rec next_of previous = function
    | [] -> previous
    | tab :: rest when tab.path = path -> (
        match rest with after :: _ -> Some after.path | [] -> previous)
    | tab :: rest -> next_of (Some tab.path) rest
  in
  let active =
    if model.active = Some path then next_of None model.tabs else model.active
  in
  { tabs = List.filter (fun tab -> tab.path <> path) model.tabs; active }

let write_file path contents =
  Binding.Call
    ( "write_file",
      [| Jv.of_string path; Jv.of_string contents |],
      (* The contents travel with the answer. By the time it comes back the tab
         may hold something else, and only what actually reached the disk may
         be recorded as saved. *)
      (fun written -> Save_done (path, contents, Binding.to_string written)),
      fun e -> Save_failed (path, e) )

let update model = function
  | UpdateContent content -> (
      match model.active with
      | None -> return model
      | Some path ->
          (* Editing invalidates whatever the last save said: the file on disk
             no longer holds what the pane is showing. *)
          return
            {
              model with
              tabs =
                set_tab path
                  (fun tab -> { tab with content; status = Idle })
                  model.tabs;
            })
  | ToggleMode editable_mode -> (
      match model.active with
      | None -> return model
      | Some path ->
          return
            {
              model with
              tabs = set_tab path (fun tab -> { tab with editable_mode }) model.tabs;
            })
  | SaveFile path -> (
      match find_tab model path with
      | None -> return model
      | Some saved ->
          return
            ~c:[ write_file path saved.content ]
            {
              model with
              tabs =
                set_tab path (fun tab -> { tab with status = Saving }) model.tabs;
            })
  | Save_done (path, contents, written) ->
      return
        {
          model with
          tabs =
            set_tab path
              (fun tab -> { tab with saved_content = contents; status = Saved written })
              model.tabs;
        }
  | Save_failed (path, e) ->
      return
        {
          model with
          tabs = set_tab path (fun tab -> { tab with status = Failed e }) model.tabs;
        }
  | Tab_selected path ->
      (* Moving to another tab drops a confirmation left pending elsewhere: it
         was asked for somewhere the reader is no longer looking. *)
      return
        {
          active = Some path;
          tabs = List.map (fun tab -> { tab with closing = false }) model.tabs;
        }
  | Close_requested path -> (
      match find_tab model path with
      | None -> return model
      (* Nothing to lose, so nothing to ask. *)
      | Some tab when not (is_modified tab) -> return (close_tab model path)
      | Some _ ->
          return
            {
              model with
              tabs = set_tab path (fun tab -> { tab with closing = true }) model.tabs;
            })
  | Close_confirmed path -> return (close_tab model path)
  | Close_cancelled path ->
      return
        {
          model with
          tabs = set_tab path (fun tab -> { tab with closing = false }) model.tabs;
        }

let status_view = function
  | Idle -> []
  | Saving -> [ elt "span" ~a:[ class_ "status" ] [ text "saving\xe2\x80\xa6" ] ]
  | Saved written ->
      [ elt "span" ~a:[ class_ "status" ] [ text (written ^ " bytes written") ] ]
  | Failed e ->
      [ elt "span" ~a:[ class_ "status error" ] [ text ("error: " ^ e) ] ]

(** One tab of the strip. A modified tab shows a dot where the cross would be,
    so that the strip says what would be lost before anything is clicked, and
    clicking that dot asks the question in place rather than in a dialog. *)
let tab_view active tab =
  let is_active = Some tab.path = active in
  let name =
    elt "button"
      ~a:
        [
          class_ "tab-name";
          (* The full path lives in the tooltip only: two files can share a
             name, and a strip of whole paths would be unreadable. *)
          attr "title" tab.path;
          onclick (fun _ -> Tab_selected tab.path);
        ]
      [ text (Filename.basename tab.path) ]
  in
  let trailing =
    if tab.closing then
      [
        elt "span" ~a:[ class_ "tab-confirm" ] [ text "close?" ];
        elt "button"
          ~a:
            [
              class_ "tab-yes";
              attr "title" "discard the changes and close";
              onclick (fun _ -> Close_confirmed tab.path);
            ]
          [ text "\xe2\x9c\x93" ];
        elt "button"
          ~a:
            [
              class_ "tab-no";
              attr "title" "keep editing";
              onclick (fun _ -> Close_cancelled tab.path);
            ]
          [ text "\xe2\x9c\x97" ];
      ]
    else if is_modified tab then
      [
        elt "button"
          ~a:
            [
              class_ "tab-close modified";
              attr "title" "unsaved changes \xe2\x80\x94 click to close";
              onclick (fun _ -> Close_requested tab.path);
            ]
          [ text "\xe2\x80\xa2" ]
      ]
    else
      [
        elt "button"
          ~a:
            [
              class_ "tab-close";
              attr "title" "close";
              onclick (fun _ -> Close_requested tab.path);
            ]
          [ text "\xc3\x97" ]
      ]
  in
  elt "div" ~key:tab.path
    ~a:
      [
        class_
          ("tab"
          ^ (if is_active then " active" else "")
          ^ if tab.closing then " closing" else "");
      ]
    (name :: trailing)

let view model =
  let strip =
    elt "div" ~a:[ class_ "tabs" ] (List.map (tab_view model.active) model.tabs)
  in
  match active_tab model with
  | None ->
      div
        ~a:[ class_ "editor" ]
        [ strip; elt "p" ~a:[ class_ "empty" ] [ text "no file open" ] ]
  | Some tab ->
      let content =
        (* Keyed on the path so that switching tabs hands over a fresh element
           rather than reusing the previous one, which would carry its scroll
           position and its selection across. *)
        if tab.editable_mode then
          (* A textarea, not an input: the pane holds whole files, which an
             input would collapse onto a single line. *)
          elt "textarea" ~key:tab.path
            ~a:
              [
                class_ "editor-content";
                value tab.content;
                oninput (fun s -> UpdateContent s);
              ]
            []
        else
          elt "pre" ~key:tab.path
            ~a:[ class_ "editor-content" ]
            [ text tab.content ]
      in
      div
        ~a:[ class_ "editor" ]
        [
          strip;
          div
            ~a:[ class_ "editor-toolbar" ]
            ([
               elt "button"
                 ~a:[ onclick (fun _ -> ToggleMode (not tab.editable_mode)) ]
                 [ text (if tab.editable_mode then "view" else "edit") ];
             ]
            (* A viewer has nothing to write back, so it is not offered the
               button. The status stays either way: losing the report of a
               failed save by glancing at the file would be worse. *)
            @ (if tab.editable_mode then
                 [
                   elt "button"
                     ~a:
                       [
                         onclick (fun _ -> SaveFile tab.path);
                         disabled (tab.status = Saving);
                       ]
                     [ text "save" ];
                 ]
               else [])
            @ status_view tab.status);
          content;
        ]

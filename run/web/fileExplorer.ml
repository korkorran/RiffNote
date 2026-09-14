(* The file tree in the left column, as a self-contained vdom component. It
   owns everything about browsing: where the tree is rooted, which directories
   are open, which listings are still in flight, and the errors the bindings
   answered with.

   It also opens the files it is asked to open — [read_file] is its call — and
   creates the ones asked for with the "+" on a directory. The application
   therefore never talks to the filesystem: it only decides what to do with a
   file once the explorer hands it over. *)

open Vdom

(** What the explorer knows about one entry. [node] carries both the kind of
    the entry and, for a directory, how far it has been opened — the two cannot
    contradict each other that way. *)
type node =
  | File
  | Other  (** neither a file nor a directory: not something to open *)
  | Collapsed
  | Loading  (** [read_dir] is in flight for this directory *)
  | Expanded of entry list

and entry = { name : string; path : string; node : node }

(** A new file being named, and the directory it will land in. *)
type creating = { parent : string; name : string }

type msg =
  | Home_known of string  (** [home_dir] answered; the tree can be rooted *)
  | Home_failed of string
  | Path_edited of string
  | Open_clicked  (** re-root the tree on the typed path *)
  | Listed of string * Jv.t  (** [read_dir] answered for that path *)
  | List_failed of string * string
  | Toggled of entry  (** a directory row was clicked *)
  | File_clicked of entry
  | File_read of string * string  (** [read_file] answered: path, contents *)
  | Read_failed of string * string
  | Create_started of string  (** the "+" of that directory was clicked *)
  | Create_name_edited of string
  | Create_cancelled
  | Create_submitted
  | Created of string * string  (** [create_file] answered: parent, path *)
  | Create_failed of string
  | Root_picker_set of bool  (** show or hide the path field *)
  | Path_paste of int * int  (** the paste shortcut, over that selection *)
  | Path_pasted of int * int * string

(** The only things the explorer has to say to the outside world. Everything
    else it handles on its own. *)
type out_msg =
  | File_opened of string * string  (** path, contents *)
  | File_created of string  (** path; the file is empty and meant to be typed in *)

type model = {
  root : string;  (** directory shown at the top of the tree *)
  tree : entry list;  (** contents of [root] *)
  path : string;  (** the path currently typed in the input *)
  reading : bool;  (** a file is being read *)
  creating : creating option;  (** a new file is being named *)
  choosing_root : bool;  (** the path field is showing *)
  error : string option;  (** last binding failure, shown above the tree *)
}

(* [update] answers with three things instead of the usual two, so it needs its
   own [return] rather than [Vdom.return]. *)
let return ?(c = []) ?(out = []) model = (model, Cmd.batch c, out)

let read_dir path =
  Binding.Call
    ( "read_dir",
      [| Jv.of_string path |],
      (fun listing -> Listed (path, listing)),
      fun e -> List_failed (path, e) )

let read_file path =
  Binding.Call
    ( "read_file",
      [| Jv.of_string path |],
      (fun contents -> File_read (path, Binding.to_string contents)),
      fun e -> Read_failed (path, e) )

let create_file parent path =
  Binding.Call
    ( "create_file",
      [| Jv.of_string path |],
      (fun _ -> Created (parent, path)),
      fun e -> Create_failed e )

let init =
  ( {
      root = "";
      tree = [];
      path = "";
      reading = false;
      creating = None;
      choosing_root = false;
      error = None;
    },
    Cmd.batch
      [
        Binding.Call
          ( "home_dir",
            [||],
            (fun home -> Home_known (Binding.to_string home)),
            fun e -> Home_failed e );
      ] )

(** Is a file being read? The application asks so that the pane on the right
    can say so while it waits. *)
let is_reading model = model.reading

(** Decode one [read_dir] answer: an array of {"name", "path", "kind"}. *)
let decode_entries listing =
  Jv.to_list
    (fun item ->
      let field name = Jv.to_string (Jv.get item name) in
      let node =
        match field "kind" with
        | "directory" -> Collapsed
        | "file" -> File
        | _ -> Other
      in
      { name = field "name"; path = field "path"; node })
    listing

(** Rebuild the tree with [f] applied to the node sitting at [path]. Paths are
    unique, so this touches at most one node. *)
let rec set_node : string -> (node -> node) -> entry list -> entry list =
 fun path f entries ->
  List.map
    (fun (e : entry) ->
      if e.path = path then { e with node = f e.node }
      else
        match e.node with
        | Expanded children ->
            { e with node = Expanded (set_node path f children) }
        | File | Other | Collapsed | Loading -> e)
    entries

let update model = function
  | Home_known home ->
      return ~c:[ read_dir home ] { model with root = home; path = home }
  | Home_failed e -> return { model with error = Some e }
  | Path_edited path -> return { model with path }
  | Open_clicked ->
      let root = String.trim model.path in
      return ~c:[ read_dir root ]
        { model with root; tree = []; creating = None; error = None }
  (* An answer for the root fills the whole tree; any other one belongs to a
     directory somewhere inside it. A listing that arrives after the tree has
     been re-rooted finds no matching path and is simply dropped. *)
  | Listed (path, listing) when path = model.root ->
      (* The directory answered, so the field that asked for it has done its
         job and folds away. A path that fails leaves it open instead, to be
         corrected without being reopened. *)
      return
        {
          model with
          tree = decode_entries listing;
          choosing_root = false;
          error = None;
        }
  | Listed (path, listing) ->
      let expand _ = Expanded (decode_entries listing) in
      return { model with tree = set_node path expand model.tree }
  | List_failed (path, e) when path = model.root ->
      return { model with tree = []; error = Some e }
  | List_failed (path, e) ->
      (* Put the directory back the way it was, so it can be tried again. *)
      let collapse _ = Collapsed in
      return
        { model with tree = set_node path collapse model.tree; error = Some e }
  | Toggled entry -> (
      match entry.node with
      | Collapsed ->
          let loading _ = Loading in
          return
            ~c:[ read_dir entry.path ]
            { model with tree = set_node entry.path loading model.tree }
      | Expanded _ ->
          let collapse _ = Collapsed in
          return { model with tree = set_node entry.path collapse model.tree }
      | Loading | File | Other -> return model)
  | File_clicked entry ->
      return
        ~c:[ read_file entry.path ]
        { model with reading = true; error = None }
  | File_read (path, contents) ->
      (* The one moment the explorer needs the application: it has a file open
         and something else has to display it. *)
      return ~out:[ File_opened (path, contents) ] { model with reading = false }
  | Read_failed (_path, e) ->
      return { model with reading = false; error = Some e }
  | Create_started parent ->
      let model =
        { model with creating = Some { parent; name = "" }; error = None }
      in
      if parent = model.root then return model
      else
        (* The row where the name is typed lives inside the directory, so a
           closed one has to be opened for it to be seen at all. Reading a
           directory that is already open costs one listing and keeps this to a
           single case. *)
        let opening = function Collapsed -> Loading | node -> node in
        return
          ~c:[ read_dir parent ]
          { model with tree = set_node parent opening model.tree }
  | Create_name_edited name -> (
      match model.creating with
      | None -> return model
      | Some c -> return { model with creating = Some { c with name } })
  | Create_cancelled -> return { model with creating = None }
  | Create_submitted -> (
      match model.creating with
      | None -> return model
      | Some { parent; name } ->
          let name = String.trim name in
          (* An empty name is not an error to report, just nothing to do. *)
          if name = "" then return model
          else
            return
              ~c:[ create_file parent (Filename.concat parent name) ]
              { model with error = None })
  | Created (parent, path) ->
      (* Re-read the directory so that the file appears in the tree, and hand
         it to the application so that it opens where it can be typed into. *)
      return ~c:[ read_dir parent ]
        ~out:[ File_created path ]
        { model with creating = None; error = None }
  | Create_failed e ->
      (* [creating] is kept: the name is still there, ready to be corrected. *)
      return { model with error = Some e }
  | Root_picker_set choosing_root -> return { model with choosing_root }
  | Path_paste (start, stop) ->
      return
        ~c:[ Clipboard.read (fun text -> Path_pasted (start, stop, text)) ]
        model
  | Path_pasted (start, stop, text) ->
      (* The field is one line, so the newline that comes with a path copied
         from a terminal or from Finder is dropped rather than pasted — which
         is what a browser does with a multi-line paste into an input. *)
      let text =
        String.concat ""
          (String.split_on_char '\n' text |> List.concat_map (String.split_on_char '\r'))
      in
      (* The selection is the field's, and the field is drawn from [path]; they
         agree, but clamping costs nothing and a [String.sub] that does not
         raises. *)
      let n = String.length model.path in
      let start = max 0 (min start n) in
      let stop = max start (min stop n) in
      let path =
        String.sub model.path 0 start ^ text
        ^ String.sub model.path stop (n - stop)
      in
      return { model with path }

(* A folder, drawn rather than written. The rest of the tree is monochrome
   glyphs that follow the text colour, which an emoji would neither do nor
   render the same way from one font to the next. *)
let folder_icon =
  svg_elt "svg"
    ~a:
      [
        attr "viewBox" "0 0 16 16";
        attr "width" "13";
        attr "height" "13";
        attr "aria-hidden" "true";
      ]
    [
      svg_elt "path"
        ~a:
          [
            attr "fill" "currentColor";
            attr "d"
              "M1.5 3h4l1.5 2h7.5a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-13a1 1 0 0 \
               1-1-1V4a1 1 0 0 1 1-1z";
          ]
        [];
    ]

(** Reveals or hides the field that re-roots the tree. It sits on the root
    line, beside the directory it would replace. *)
let folder_button showing =
  elt "button"
    ~a:
      [
        class_ "folder";
        attr "title" "open another folder";
        onclick (fun _ -> Root_picker_set (not showing));
      ]
    [ folder_icon ]

(** The "+" that starts naming a file inside [dir]. *)
let add_button dir =
  elt "button"
    ~a:
      [
        class_ "add";
        attr "title" ("new file in " ^ Filename.basename dir);
        onclick (fun _ -> Create_started dir);
      ]
    [ text "+" ]

(** The row a new file is named in. It sits inside the directory it will land
    in, so that what is being created and where is one glance rather than two. *)
let new_file_row name =
  (* Entry paths are absolute, so this key cannot collide with one of theirs. *)
  elt "li" ~key:"new-file"
    [
      div
        ~a:[ class_ "row new-file" ]
        [
          input
            ~a:
              [
                type_ "text";
                class_ "new-file-name";
                value name;
                attr "placeholder" "new file name";
                autofocus;
                oninput (fun s -> Create_name_edited s);
                onkeydown_cancel (fun (e : key_event) ->
                    if e.which = 13 then Some Create_submitted
                    else if e.which = 27 then Some Create_cancelled
                    else None);
              ]
            [];
          elt "button"
            ~a:[ attr "title" "create"; onclick (fun _ -> Create_submitted) ]
            [ text "\xe2\x9c\x93" ];
          elt "button"
            ~a:[ attr "title" "cancel"; onclick (fun _ -> Create_cancelled) ]
            [ text "\xe2\x9c\x97" ];
        ];
    ]

(* [parent] is the directory this list is the contents of, which is what tells
   the new-file row which of the nested lists to appear in. *)
let rec view_entries ~creating ~parent entries =
  let naming_here =
    match creating with
    | Some (c : creating) when c.parent = parent -> [ new_file_row c.name ]
    | _ -> []
  in
  elt "ul" ~a:[ class_ "tree" ]
    (naming_here @ List.map (entry_view ~creating) entries)

and entry_view ~creating e =
  let row =
    match e.node with
    | File ->
        elt "button"
          ~a:[ class_ "row file"; onclick (fun _ -> File_clicked e) ]
          [ text e.name ]
    | Other ->
        (* A broken symlink, a socket: nothing to open, so nothing to click
           either. *)
        elt "span" ~a:[ class_ "row other" ] [ text e.name ]
    | Collapsed | Loading | Expanded _ ->
        let marker =
          match e.node with
          | Expanded _ -> "\xe2\x96\xbe"
          | Loading -> "\xc2\xb7\xc2\xb7\xc2\xb7"
          | File | Other | Collapsed -> "\xe2\x96\xb8"
        in
        (* The "+" cannot go inside the row: a button does not nest in a
           button, so the two share a wrapper instead. *)
        div
          ~a:[ class_ "row-wrap" ]
          [
            elt "button"
              ~a:[ class_ "row dir"; onclick (fun _ -> Toggled e) ]
              [
                elt "span" ~a:[ class_ "marker" ] [ text marker ];
                text e.name;
              ];
            add_button e.path;
          ]
  in
  let children =
    match e.node with
    | Expanded children -> [ view_entries ~creating ~parent:e.path children ]
    | File | Other | Collapsed | Loading -> []
  in
  (* Keyed on the path so that expanding one directory does not make vdom
     re-create the rows of its siblings. *)
  elt "li" ~key:e.path (row :: children)

let view model =
  let cannot_open = model.reading || String.trim model.path = "" in
  div
    ~a:[ class_ "explorer" ]
    ((* Hidden until the folder button asks for it: the tree is what the column
        is for, and the path of another directory is wanted rarely. *)
     (if model.choosing_root then
        [
          div
            ~a:[ class_ "actions" ]
            [
              input
                ~a:
                  [
                    type_ "text";
                    class_ "path";
                    value model.path;
                    attr "placeholder" "/path/to/folder";
                    (* Revealed to be typed in, so it takes the caret with it. *)
                    autofocus;
                    (* The window has no Edit menu, so the paste shortcut has to
                       be served by the page; see clipboard.ml. *)
                    Clipboard.on_shortcut (fun start stop ->
                        Path_paste (start, stop));
                    oninput (fun s -> Path_edited s);
                    (* Enter opens too: a path input that only answers to the
                       button would be a surprise. Escape folds it back. *)
                    onkeydown_cancel (fun (e : key_event) ->
                        if e.which = 13 && not cannot_open then Some Open_clicked
                        else if e.which = 27 then Some (Root_picker_set false)
                        else None);
                  ]
                [];
              elt "button"
                ~a:[ onclick (fun _ -> Open_clicked); disabled cannot_open ]
                [ text "open" ];
            ];
        ]
      else [])
    @ [
        (* The root is a directory like any other, so it gets a "+" too —
           without one there would be no way to add a file beside the ones the
           tree opens on. *)
        div
          ~a:[ class_ "root" ]
          ((folder_button model.choosing_root
           :: [ elt "span" ~a:[ class_ "root-path" ] [ text model.root ] ])
          @ if model.root = "" then [] else [ add_button model.root ]);
      ]
    @ (match model.error with
      | Some e -> [ elt "p" ~a:[ class_ "error" ] [ text ("error: " ^ e) ] ]
      | None -> [])
    @ [ view_entries ~creating:model.creating ~parent:model.root model.tree ])

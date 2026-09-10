(* Elm-style application: the UI is a pure function of a model, and every
   interaction goes through a message. Nothing here looks up or mutates a DOM
   node by hand — [Vdom_blit] diffs the tree returned by [view] and patches the
   document itself.

   Two JavaScript worlds meet in this file:
   - [Js_browser] (shipped with vdom) for the DOM: the mount point and the
     page-ready event;
   - [Jv] (brr) for the bindings that main.ml exposes on the global object.
     They never exchange values, so the two stay side by side. *)

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

(** Register the function in the global object in order to use it from the main
    application *)
let register : string -> 'a -> unit =
 fun name f -> Jv.set Jv.global name (Jv.repr f)

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

type msg =
  | Home_known of string  (** [home_dir] answered; the tree can be rooted *)
  | Path_edited of string
  | Open_clicked  (** re-root the tree on the typed path *)
  | Listed of string * Jv.t  (** [read_dir] answered for that path *)
  | List_failed of string * string
  | Toggled of entry  (** a directory row was clicked *)
  | File_clicked of entry
  | File_read of string
  | Pushed of string  (** the native side called [show] *)
  | Failed of string
  | Editor_msg of ContentEditor.msg  (** the content pane spoke *)

(** The whole state of the UI. *)
type model = {
  root : string;  (** directory shown at the top of the tree *)
  tree : entry list;  (** contents of [root] *)
  path : string;  (** the file path currently typed in the input *)
  editor : ContentEditor.model;  (** the content pane, a component of its own *)
  error : string option;  (** last binding failure, shown above the pane *)
  reading : bool;  (** a file is being read *)
}

(* Calling a binding is asynchronous, so it is expressed as a command instead
   of being run from [update]: that keeps [update] a pure function of the model
   and confines the JavaScript call to the handler below. [Vdom.Cmd.t] is an
   open type, meant to be extended this way. *)
type 'msg Vdom.Cmd.t +=
  | Call of string * Jv.t array * (Jv.t -> 'msg) * (string -> 'msg)

let webview_cmds =
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

let read_dir path =
  Call
    ( "read_dir",
      [| Jv.of_string path |],
      (fun listing -> Listed (path, listing)),
      fun e -> List_failed (path, e) )

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

let init =
  Vdom.return
    ~c:
      [
        Call
          ( "home_dir",
            [||],
            (fun home -> Home_known (to_string home)),
            fun e -> Failed e );
      ]
    {
      root = "";
      tree = [];
      path = "";
      editor = ContentEditor.init;
      error = None;
      reading = false;
    }

let update model = function
  | Home_known home ->
      Vdom.return ~c:[ read_dir home ] { model with root = home; path = home }
  | Path_edited path -> Vdom.return { model with path }
  | Open_clicked ->
      let root = String.trim model.path in
      Vdom.return ~c:[ read_dir root ] { model with root; tree = [] }
  (* An answer for the root fills the whole tree; any other one belongs to a
     directory somewhere inside it. A listing that arrives after the tree has
     been re-rooted finds no matching path and is simply dropped. *)
  | Listed (path, listing) when path = model.root ->
      Vdom.return { model with tree = decode_entries listing; error = None }
  | Listed (path, listing) ->
      let expand _ = Expanded (decode_entries listing) in
      Vdom.return { model with tree = set_node path expand model.tree }
  | List_failed (path, e) when path = model.root ->
      Vdom.return { model with tree = []; error = Some e }
  | List_failed (path, e) ->
      (* Put the directory back the way it was, so it can be tried again. *)
      let collapse _ = Collapsed in
      Vdom.return
        {
          model with
          tree = set_node path collapse model.tree;
          error = Some e;
        }
  | Toggled entry -> (
      match entry.node with
      | Collapsed ->
          let loading _ = Loading in
          Vdom.return
            ~c:[ read_dir entry.path ]
            { model with tree = set_node entry.path loading model.tree }
      | Expanded _ ->
          let collapse _ = Collapsed in
          Vdom.return { model with tree = set_node entry.path collapse model.tree }
      | Loading | File | Other -> Vdom.return model)
  | File_clicked entry ->
      Vdom.return
        ~c:
          [
            Call
              ( "read_file",
                [| Jv.of_string entry.path |],
                (fun contents -> File_read (to_string contents)),
                fun e -> Failed e );
          ]
        {
          model with
          (* The pane is pointed at the file before its contents arrive, so
             that a save issued right after the read carries the right path. *)
          editor = ContentEditor.set_file_path model.editor entry.path;
          reading = true;
          error = None;
        }
  | File_read contents ->
      Vdom.return
        {
          model with
          editor = ContentEditor.set_content model.editor contents;
          reading = false;
        }
  | Pushed text ->
      Vdom.return { model with editor = ContentEditor.set_content model.editor text }
  | Failed e -> Vdom.return { model with error = Some e; reading = false }
  (* The pane runs its own update; whatever it asks for comes back here wrapped
     in [Editor_msg], so the two message types never mix. *)
  | Editor_msg m ->
      let editor, cmd = ContentEditor.update model.editor m in
      ({ model with editor }, Vdom.Cmd.map (fun m -> Editor_msg m) cmd)

let rec view_entries entries =
  let open Vdom in
  elt "ul" ~a:[ class_ "tree" ]
    (List.map
       (fun e ->
         let row =
           match e.node with
           | File ->
               elt "button"
                 ~a:[ class_ "row file"; onclick (fun _ -> File_clicked e) ]
                 [ text e.name ]
           | Other ->
               (* A broken symlink, a socket: nothing to open, so nothing to
                  click either. *)
               elt "span" ~a:[ class_ "row other" ] [ text e.name ]
           | Collapsed | Loading | Expanded _ ->
               let marker =
                 match e.node with
                 | Expanded _ -> "\xe2\x96\xbe"
                 | Loading -> "\xc2\xb7\xc2\xb7\xc2\xb7"
                 | File | Other | Collapsed -> "\xe2\x96\xb8"
               in
               elt "button"
                 ~a:[ class_ "row dir"; onclick (fun _ -> Toggled e) ]
                 [
                   elt "span" ~a:[ class_ "marker" ] [ text marker ];
                   text e.name;
                 ]
         in
         let children =
           match e.node with
           | Expanded children -> [ view_entries children ]
           | File | Other | Collapsed | Loading -> []
         in
         (* Keyed on the path so that expanding one directory does not make
            vdom re-create the rows of its siblings. *)
         elt "li" ~key:e.path (row :: children))
       entries)

let view { root; tree; path; editor; error; reading } =
  let open Vdom in
  let cannot_open = reading || String.trim path = "" in
  div
    ~a:[ class_ "layout" ]
    [
      div
        ~a:[ class_ "controls" ]
        [
          elt "h2" [ text "RiffNote" ];
          div
            ~a:[ class_ "actions" ]
            [
              input
                ~a:
                  [
                    type_ "text";
                    class_ "path";
                    value path;
                    attr "placeholder" "/path/to/folder";
                    oninput (fun s -> Path_edited s);
                    (* Enter opens too: a path input that only answers to the
                       button would be a surprise. *)
                    onkeydown_cancel (fun (e : key_event) ->
                        if e.which = 13 && not cannot_open then
                          Some Open_clicked
                        else None);
                  ]
                [];
              elt "button"
                ~a:[ onclick (fun _ -> Open_clicked); disabled cannot_open ]
                [ text "open" ];
            ];
          elt "p" ~a:[ class_ "root" ] [ text root ];
          view_entries tree;
        ];
      (* The id is kept so the rules of style.css still apply. *)
      div
        ~a:[ attr "id" "out" ]
        ((match error with
         | Some e -> [ elt "p" ~a:[ class_ "error" ] [ text ("error: " ^ e) ] ]
         | None -> [])
        @ [
            (if reading then text "reading\xe2\x80\xa6"
             else Vdom.map (fun m -> Editor_msg m) (ContentEditor.view editor));
          ]);
    ]

let app = Vdom.app ~init ~update ~view ()

let run () =
  (* This code is executed once the view is initialized, the elements are all
  ready *)
  let container =
    Option.get (Js_browser.Document.get_element_by_id Js_browser.document "app")
  in
  let running = Vdom_blit.run ~env:webview_cmds ~container app in
  (* main.ml evaluates show("...") to forward a line typed in the terminal.
     Injecting it as a message keeps that path identical to a click: the view
     stays the only thing that touches the DOM. *)
  register "show" (fun (s : Jstr.t) ->
      Vdom_blit.process running (Pushed (Jstr.to_string s)))

let () =
  Js_browser.Window.add_event_listener Js_browser.window
    Js_browser.Event.DOMContentLoaded
    (fun _ -> run ())
    false

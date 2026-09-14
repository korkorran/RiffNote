(** The content pane in the right column.

    The editor holds several files at once, one tab each, and owns everything
    about them: what they contain, whether they are being viewed or edited,
    whether they differ from the disk, and what became of their last save. It
    writes them back itself — [write_file] is its call — so the application
    never has to know when a save happens or how it went.

    Tabs, messages and save statuses stay private: the application wraps [msg]
    on the way up and never inspects it. *)

type model
type msg

val init : model
(** No file open. The pane says so until it is handed one. *)

val open_file : model -> path:string -> contents:string -> model
(** Show a file read from disk, in a new tab. A file that is already open is
    only brought to the front, keeping whatever has been typed into it: reading
    it again would throw those edits away. *)

val open_new_file : model -> path:string -> model
(** Show a file that has just been created: empty, and straight in edit mode,
    since it was asked for in order to be written in. *)

val update : model -> msg -> model * msg Vdom.Cmd.t

val view : model -> msg Vdom.vdom

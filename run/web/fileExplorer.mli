(** The file tree in the left column.

    The explorer owns the whole of browsing: rooting the tree, expanding
    directories, reading the file that was clicked, and reporting whatever the
    bindings failed at. Its messages and its entries stay private — the
    application wraps [msg] on the way up and never inspects it. *)

type model
type msg

(** The one thing the explorer needs the application for: a file is open, and
    something else has to display it. *)
type out_msg = File_opened of string * string  (** path, contents *)

val init : model * msg Vdom.Cmd.t
(** Starts empty, and asks the native side for the home directory to root the
    tree on. *)

val update : model -> msg -> model * msg Vdom.Cmd.t * out_msg list

val view : model -> msg Vdom.vdom

val is_reading : model -> bool
(** Whether a file is being read, so that the pane displaying it can say so
    while it waits. *)

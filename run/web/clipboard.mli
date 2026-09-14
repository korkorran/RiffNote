(** Serving the paste shortcut from the page.

    The window has no menu bar, so macOS never turns Cmd+V into a paste: the
    keystroke arrives as a plain keydown and nothing acts on it. These two
    pieces put the behaviour back — an attribute that catches the shortcut, and
    a command that reads the clipboard — for any text field that wants it. *)

val on_shortcut : (int -> int -> 'msg) -> 'msg Vdom.attribute
(** [on_shortcut f] fires [f start stop] when the shortcut is pressed in a text
    field, [start] and [stop] delimiting the selection the pasted text is meant
    to replace. Other keystrokes are left alone. *)

val read : (string -> 'msg) -> 'msg Vdom.Cmd.t
(** The command to answer [on_shortcut] with. It yields the clipboard text, and
    yields nothing at all if there is nothing to read. *)

val env : Vdom_blit.env
(** To be merged into the environment given to [Vdom_blit.run]. *)

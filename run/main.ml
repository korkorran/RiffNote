let () =
  (* Library version info (no window needed). *)
  let v = Webview.version () in
  Printf.printf "using webview %s\n%!" v.Webview.version_number;

  let w = Webview.create ~debug:true () in
  Webview.set_title w "Hello from OCaml";
  (* Two columns side by side need more room than the 480x320 the example
     started with, and the output pane is now meant to hold a whole file. *)
  Webview.set_size w ~width:900 ~height:600 Webview.Hint_none;

  (* Native handles (opaque pointers, for platform-specific FFI such as a file
     dialog). 0n means unavailable. *)
  Printf.printf "native window handle = %nx\n%!" (Webview.get_window w);
  ignore (Webview.get_native_handle w Webview.Browser_controller);

  (* Expose window.home_dir() to JS. The page opens on the user's home
     directory, and JavaScript has no way to know where that is. *)
  Webview.bind w "home_dir" (fun id req ->
      Printf.printf "binding called <home_dir>: id=%s req=%s\n%!" id req;
      let home =
        match Sys.getenv_opt "HOME" with
        | Some home -> home
        (* Windows spells it differently; "." at least lists something. *)
        | None -> Option.value (Sys.getenv_opt "USERPROFILE") ~default:"."
      in
      Webview.return w id ~error:false ~result:(Utils.js_quote home));

  (* Expose window.read_file(path) to JS. It resolves with the contents of the
     file as a string, or rejects with an error message.

     [Webview.return] wants a JSON value, so both the contents and the error go
     through [Utils.js_quote], which produces a quoted literal that is valid
     JSON too. A file that is not valid UTF-8 would therefore not survive the
     trip: this reads text files, not arbitrary bytes.

     The read happens on the UI thread, so a very large file would freeze the
     window while it is loaded. Moving it off that thread means doing the work
     in a [Thread] and calling [Webview.dispatch] to come back, since the
     webview may only be touched from the thread that called [run]. *)
  Webview.bind w "read_file" (fun id req ->
      Printf.printf "binding called <read_file>: id=%s req=%s\n%!" id req;
      match Utils.json_string_arg req with
      | None ->
          Webview.return w id ~error:true
            ~result:(Utils.js_quote "read_file expects a file path as a string")
      | Some path -> (
          match In_channel.with_open_bin path In_channel.input_all with
          | contents ->
              Webview.return w id ~error:false ~result:(Utils.js_quote contents)
          | exception Sys_error msg ->
              Webview.return w id ~error:true ~result:(Utils.js_quote msg)));

  (* Expose window.read_dir(path) to JS. It resolves with the direct contents
     of the directory, as a JSON array of {"name": ..., "kind": ...} where kind
     is "file", "directory" or "other".

     One level only: to walk down, the page calls read_dir again on the child.
     That keeps a single call bounded, which matters here because — like
     read_file above — it runs on the UI thread. *)
  Webview.bind w "read_dir" (fun id req ->
      Printf.printf "binding called <read_dir>: id=%s req=%s\n%!" id req;
      match Utils.json_string_arg req with
      | None ->
          Webview.return w id ~error:true
            ~result:
              (Utils.js_quote "read_dir expects a directory path as a string")
      | Some path -> (
          match Sys.readdir path with
          | entries ->
              (* [readdir] order is whatever the filesystem hands back, so the
                 listing is sorted here to stay stable between calls. Hidden
                 entries are kept: filtering them is the page's business. *)
              Array.sort String.compare entries;
              let kind name =
                (* [stat] follows symlinks, so a link to a folder is reported
                   as a directory and stays navigable. An entry that cannot be
                   stat'ed at all — a broken link, a directory we may list but
                   not enter — is reported as "other" instead of failing the
                   whole listing. *)
                match (Unix.stat (Filename.concat path name)).Unix.st_kind with
                | Unix.S_REG -> "file"
                | Unix.S_DIR -> "directory"
                | _ -> "other"
                | exception Unix.Unix_error _ -> "other"
              in
              let item name =
                (* The full path travels with the entry: joining it back in
                   the page would mean hardcoding a separator, and
                   [Filename.concat] already knows the right one. *)
                Printf.sprintf "{\"name\":%s,\"path\":%s,\"kind\":%s}"
                  (Utils.js_quote name)
                  (Utils.js_quote (Filename.concat path name))
                  (Utils.js_quote (kind name))
              in
              let result =
                "["
                ^ String.concat ","
                    (Array.to_list (Array.map item entries))
                ^ "]"
              in
              Webview.return w id ~error:false ~result
          | exception Sys_error msg ->
              Webview.return w id ~error:true ~result:(Utils.js_quote msg)));

  (* Expose window.write_file(path, contents) to JS. It resolves with the
     number of bytes written, or rejects with an error message.

     The file is truncated and rewritten in place, so an interrupted save
     leaves it damaged rather than untouched; writing to a temporary file and
     renaming it over the original is the way to make that atomic, once it
     matters.

     Like read_file, this runs on the UI thread, and the contents travel as a
     JSON string: it writes text files, not arbitrary bytes. *)
  Webview.bind w "write_file" (fun id req ->
      (* [req] holds the whole file, so only the path is printed: echoing the
         contents would dump the document into the terminal at every save. *)
      match Utils.json_string_args req with
      | Some [ path; contents ] -> (
          Printf.printf "binding called <write_file>: id=%s path=%s bytes=%d\n%!"
            id path (String.length contents);
          match
            Out_channel.with_open_bin path (fun oc ->
                Out_channel.output_string oc contents)
          with
          | () ->
              Webview.return w id ~error:false
                ~result:(string_of_int (String.length contents))
          | exception Sys_error msg ->
              Webview.return w id ~error:true ~result:(Utils.js_quote msg))
      | _ ->
          Printf.printf "binding called <write_file>: id=%s (bad arguments)\n%!" id;
          Webview.return w id ~error:true
            ~result:
              (Utils.js_quote
                 "write_file expects a file path and its contents, as strings"));

  (* Load the page from on-disk files (web/) instead of an inline HTML string.
     The CSS and JS referenced with relative paths in index.html are resolved
     relative to that file. We locate the web/ directory from the executable
     location, so it works both installed and from the build tree. *)
  let index = Filename.concat (Webview.Utils.web_dir ()) "index.html" in
  Webview.navigate w ("file://" ^ index);

  Webview.run w;
  Webview.destroy w

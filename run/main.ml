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

  (* Expose window.add(a, b) to JS. [req] is a JSON array of the arguments. *)
  Webview.bind w "add" (fun id req ->
      Printf.printf "binding called <add>: id=%s req=%s\n%!" id req;
      let result =
        match Scanf.sscanf_opt req "[%d,%d]" (fun a b -> a + b) with
        | Some n -> string_of_int n
        | None -> "null"
      in
      Webview.return w id ~error:false ~result);

  (* Expose window.os_type() to JS. Returns the host OS as a JSON string. *)
  Webview.bind w "os_type" (fun id req ->
      Printf.printf "binding called <os_type>: id=%s req=%s\n%!" id req;
      let result =
        Printf.sprintf "show(%s)" (Utils.js_quote (Utils.detect_os ()))
      in
      Webview.eval w result;
      Webview.return w id ~error:false ~result:"");

  (* Expose window.read_file(path) to JS. It resolves with the contents of the
     file as a string, or rejects with an error message.

     [Webview.return] wants a JSON value, so both the contents and the error go
     through [Utils.js_quote], which produces a quoted literal that is valid
     JSON too. A file that is not valid UTF-8 would therefore not survive the
     trip: this reads text files, not arbitrary bytes.

     The read happens on the UI thread, so a very large file would freeze the
     window while it is loaded; the terminal reader below shows the pattern to
     move that off the UI thread if it ever matters. *)
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

  (* Load the page from on-disk files (web/) instead of an inline HTML string.
     The CSS and JS referenced with relative paths in index.html are resolved
     relative to that file. We locate the web/ directory from the executable
     location, so it works both installed and from the build tree. *)
  let index = Filename.concat (Webview.Utils.web_dir ()) "index.html" in
  Webview.navigate w ("file://" ^ index);

  (* Forward the terminal to the page: every line typed here is displayed in
     <pre id="out"> by the [show] function that app.ml registered on the global
     object.

     [input_line] blocks, so it runs on its own thread. The webview must only
     be touched from the UI thread (the one that called [run]), so the JS call
     goes through [dispatch] rather than being evaluated directly. *)
  Printf.printf "type a message and press <Enter> to display it in the window\n%!";
  let _ =
    Thread.create
      (fun () ->
        try
          while true do
            let line = input_line stdin in
            (* [show] only exists once app.js has run its DOMContentLoaded
               handler; guard against a message typed before the page loads. *)
            let js =
              Printf.sprintf "if (typeof show === 'function') show(%s);"
                (Utils.js_quote line)
            in
            Webview.dispatch w (fun w -> Webview.eval w js)
          done
        with End_of_file -> ())
      ()
  in

  Webview.run w;
  Webview.destroy w

let () =
  (* Library version info (no window needed). *)
  let v = Webview.version () in
  Printf.printf "using webview %s\n%!" v.Webview.version_number;

  let w = Webview.create ~debug:true () in
  Webview.set_title w "Sun notes";
  (* Two columns side by side need more room than the 480x320 the example
     started with, and the output pane is now meant to hold a whole file. *)
  Webview.set_size w ~width:900 ~height:600 Webview.Hint_none;

  (* Native handles (opaque pointers, for platform-specific FFI such as a file
     dialog). 0n means unavailable. *)
  Printf.printf "native window handle = %nx\n%!" (Webview.get_window w);
  ignore (Webview.get_native_handle w Webview.Browser_controller);

  (* Every call the page can make into the native side lives in binding.ml,
     where each one is an Lwt computation rather than work done on the UI
     thread. They are registered here, before the page is loaded, so that
     nothing it does at startup finds a missing function. *)
  Binding.install w;

  (* Load the page from on-disk files (web/) instead of an inline HTML string.
     The CSS and JS referenced with relative paths in index.html are resolved
     relative to that file. We locate the web/ directory from the executable
     location, so it works both installed and from the build tree. *)
  let index = Filename.concat (Webview.Utils.web_dir ()) "index.html" in
  Webview.navigate w ("file://" ^ index);

  (* The two event loops get a thread each, and the assignment is not
     arbitrary: Cocoa requires the UI loop to own the process's main thread, so
     [Webview.run] keeps it and Lwt moves to a spawned thread. Started before
     [Webview.run] so the Lwt loop is up by the time the page can call a
     binding — [Lwt_preemptive.run_in_main] has nowhere to hand work otherwise. *)
  let _ : Thread.t =
    Thread.create (fun () -> Lwt_main.run (Binding.serve ())) ()
  in

  Webview.run w;
  Webview.destroy w

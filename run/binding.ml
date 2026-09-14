(* Everything the page can ask the native side to do.

   The handlers run on the Lwt event loop rather than on the UI thread. That
   matters here because all of them touch the filesystem: on the UI thread a
   slow disk, a network mount or a large file freezes the window for as long as
   the call takes, and several calls queue up behind each other. On the Lwt
   loop they interleave, and the window keeps drawing while they wait.

   Two event loops are in play. [Webview.run] keeps the process's main thread —
   Cocoa insists on it — and [Lwt_main.run] gets a thread of its own; see
   main.ml. [lwt_bind] below is the hop between the two. *)

open Lwt.Syntax

(* Expose [name] as a binding whose handler is an ordinary Lwt computation.

   The callback [Webview.bind] wants must return [unit], so there is nowhere to
   hand a promise back to; it instead *starts* the computation and returns at
   once. [run_in_main] moves that start onto the thread running [Lwt_main.run],
   the only one allowed to touch the Lwt scheduler, and [Lwt.async] leaves it to
   finish on its own — the answer travels back later through [Webview.return],
   which is the one function in the API safe to call from any thread. *)
let lwt_bind w name (f : string -> string -> unit Lwt.t) =
  Webview.bind w name (fun id req ->
      Lwt_preemptive.run_in_main (fun () ->
          Lwt.return (Lwt.async (fun () -> f id req))))

(* What to tell the page when a call fails. [Lwt_unix] and [Lwt_io] raise
   [Unix_error] where the blocking stdlib raised [Sys_error], so the path is put
   back in front of the reason to keep the wording the page used to show. *)
let describe = function
  | Unix.Unix_error (e, _, arg) when arg <> "" ->
      Printf.sprintf "%s: %s" arg (Unix.error_message e)
  | Unix.Unix_error (e, fn, _) -> Printf.sprintf "%s: %s" fn (Unix.error_message e)
  | Sys_error msg | Failure msg -> msg
  | exn -> Printexc.to_string exn

(* Settle the promise the page is waiting on with what [f] produced, or with
   why it could not be produced.

   Every path goes through here on purpose: a handler that raised without
   answering would leave the page waiting on a promise that never settles, and
   [Lwt.async] would swallow the exception on the way out. Bad arguments are
   raised as [Failure] and come out as a rejection like any other failure. *)
let answer w id f =
  Lwt.catch
    (fun () ->
      let* result = f () in
      Webview.return w id ~error:false ~result;
      Lwt.return_unit)
    (fun exn ->
      Webview.return w id ~error:true ~result:(Utils.js_quote (describe exn));
      Lwt.return_unit)

(* The first string argument of a request, for the bindings that take one. *)
let one_path binding req =
  match Utils.json_string_arg req with
  | Some path -> path
  | None -> failwith (binding ^ " expects a file path as a string")

(* The home directory. The page opens on it, and JavaScript has no way to know
   where it is. Nothing here waits on anything, but it goes through the same
   path as the rest so that every binding is registered the same way. *)
let home_dir w =
  lwt_bind w "home_dir" (fun id req ->
      Printf.printf "binding called <home_dir>: id=%s req=%s\n%!" id req;
      answer w id (fun () ->
          let home =
            match Sys.getenv_opt "HOME" with
            | Some home -> home
            (* Windows spells it differently; "." at least lists something. *)
            | None -> Option.value (Sys.getenv_opt "USERPROFILE") ~default:"."
          in
          Lwt.return (Utils.js_quote home)))

(* The contents of a file, as a string.

   [Webview.return] wants a JSON value, so both the contents and the error go
   through [Utils.js_quote], which produces a quoted literal that is valid JSON
   too. A file that is not valid UTF-8 would therefore not survive the trip:
   this reads text files, not arbitrary bytes. *)
let read_file w =
  lwt_bind w "read_file" (fun id req ->
      Printf.printf "binding called <read_file>: id=%s req=%s\n%!" id req;
      answer w id (fun () ->
          let path = one_path "read_file" req in
          let* contents =
            Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read
          in
          Lwt.return (Utils.js_quote contents)))

(* The direct contents of a directory, as a JSON array of
   {"name", "path", "kind"} where kind is "file", "directory" or "other".

   One level only: to walk down, the page calls read_dir again on the child. *)
let read_dir w =
  lwt_bind w "read_dir" (fun id req ->
      Printf.printf "binding called <read_dir>: id=%s req=%s\n%!" id req;
      answer w id (fun () ->
          let path = one_path "read_dir" req in
          let* entries =
            Lwt_stream.to_list (Lwt_unix.files_of_directory path)
          in
          (* Unlike [Sys.readdir], the stream hands back "." and ".."; they are
             not entries the tree should show. The rest is sorted here to stay
             stable between calls, and hidden entries are kept — filtering them
             is the page's business. *)
          let entries =
            List.filter (fun name -> name <> "." && name <> "..") entries
          in
          let entries = List.sort String.compare entries in
          let kind name =
            (* [stat] follows symlinks, so a link to a folder is reported as a
               directory and stays navigable. An entry that cannot be stat'ed at
               all — a broken link, a directory we may list but not enter — is
               reported as "other" instead of failing the whole listing. *)
            Lwt.catch
              (fun () ->
                let* st = Lwt_unix.stat (Filename.concat path name) in
                Lwt.return
                  (match st.Unix.st_kind with
                  | Unix.S_REG -> "file"
                  | Unix.S_DIR -> "directory"
                  | _ -> "other"))
              (fun _ -> Lwt.return "other")
          in
          let item name =
            let* kind = kind name in
            (* The full path travels with the entry: joining it back in the page
               would mean hardcoding a separator, and [Filename.concat] already
               knows the right one. *)
            Lwt.return
              (Printf.sprintf "{\"name\":%s,\"path\":%s,\"kind\":%s}"
                 (Utils.js_quote name)
                 (Utils.js_quote (Filename.concat path name))
                 (Utils.js_quote kind))
          in
          (* [map_s] rather than [map_p]: the entries are stat'ed one after the
             other, which keeps a large directory from opening as many file
             descriptors as it has children. *)
          let* items = Lwt_list.map_s item entries in
          Lwt.return ("[" ^ String.concat "," items ^ "]")))

(* Write a file, resolving with the number of bytes written.

   The file is truncated and rewritten in place, so an interrupted save leaves
   it damaged rather than untouched; writing to a temporary file and renaming it
   over the original is the way to make that atomic, once it matters. *)
let write_file w =
  lwt_bind w "write_file" (fun id req ->
      answer w id (fun () ->
          match Utils.json_string_args req with
          | Some [ path; contents ] ->
              (* [req] holds the whole file, so only the path is printed:
                 echoing the contents would dump the document into the terminal
                 at every save. *)
              Printf.printf
                "binding called <write_file>: id=%s path=%s bytes=%d\n%!" id
                path (String.length contents);
              let* () =
                Lwt_io.with_file ~mode:Lwt_io.Output path (fun oc ->
                    Lwt_io.write oc contents)
              in
              Lwt.return (string_of_int (String.length contents))
          | _ ->
              Printf.printf "binding called <write_file>: id=%s (bad arguments)\n%!"
                id;
              failwith
                "write_file expects a file path and its contents, as strings"))

(* Create an empty file, resolving with its path.

   [O_EXCL] rather than a [Sys.file_exists] check beforehand: the kernel refuses
   to create a path that already exists, which leaves no window between the test
   and the creation. This binding adds a file to a directory, it never replaces
   one — that is what write_file is for. *)
let create_file w =
  lwt_bind w "create_file" (fun id req ->
      Printf.printf "binding called <create_file>: id=%s req=%s\n%!" id req;
      answer w id (fun () ->
          let path = one_path "create_file" req in
          let* fd =
            Lwt_unix.openfile path
              [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
              0o644
          in
          let* () = Lwt_unix.close fd in
          Lwt.return (Utils.js_quote path)))

(** Register every binding on [w]. Called from the UI thread before the page is
    loaded, so that nothing the page does at startup finds a missing function. *)
let install w =
  (* [Lwt.async] sends whatever a handler raised here, and the default hook
     ends the process. [answer] already catches failures inside a handler, so
     reaching this means a bug in the plumbing — worth seeing, not worth
     dying for. *)
  (Lwt.async_exception_hook :=
     fun exn -> Printf.eprintf "lwt: %s\n%!" (Printexc.to_string exn));
  home_dir w;
  read_file w;
  read_dir w;
  write_file w;
  create_file w

(** The backend's own task, to be handed to [Lwt_main.run].

    It never resolves, and that is the point: should [Lwt_main.run] return, the
    Lwt loop would stop and every later [run_in_main] — that is, every binding
    the page calls — would have no loop to hand its work to, leaving the page
    waiting forever on promises nobody can settle. Long-lived work belongs
    here, beside the wait. *)
let serve () =
  let* () = Lwt_io.printl "[lwt] backend loop started" in
  fst (Lwt.wait ())

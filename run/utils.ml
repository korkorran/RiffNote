(* Best-effort detection of the host OS. On Unix systems [Sys.os_type] only
   reports "Unix", so we refine it with `uname` to tell macOS from Linux. *)
let detect_os () =
  match Sys.os_type with
  | "Win32" -> "Windows"
  | "Cygwin" -> "Cygwin"
  | _ ->
      let uname =
        try
          let ic = Unix.open_process_in "uname -s" in
          let line = try input_line ic with End_of_file -> "" in
          ignore (Unix.close_process_in ic);
          String.trim line
        with _ -> ""
      in
      (match uname with
       | "Darwin" -> "macOS"
       | "Linux" -> "Linux"
       | "" -> "Unix"
       | other -> other)

(* Quote a string as a JavaScript double-quoted literal.

   [Printf]'s "%S" is deliberately not used here: it escapes bytes >= 0x80 as a
   decimal "\ddd", which JavaScript reads as a legacy *octal* escape — a
   message containing "é" would reach the page mangled. JS source is UTF-8, so
   raw bytes are passed through and only the characters that would close the
   literal or break the line get escaped. *)
let js_quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
          Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* Decode a binding request: [req] is the JSON array of the JS arguments, and
   this returns every string it holds, in order. Arguments that are not strings
   are skipped rather than reported: a binding states what it expects by
   matching on the list it gets back.

   Written by hand rather than with [Scanf]'s "%S" for the mirror image of the
   reason [js_quote] avoids "%S": JSON escapes are not OCaml's. JSON spells a
   non-ASCII character "\u00e9" where an OCaml literal spells it "\233", and
   "%S" would read the former as the seven characters `u00e9` preceded by a
   backslash it does not recognise. *)
let json_string_args req =
  let n = String.length req in
  (* The four hex digits of a \uXXXX escape, as a code point. *)
  let hex4 i =
    let digit c =
      match c with
      | '0' .. '9' -> Some (Char.code c - Char.code '0')
      | 'a' .. 'f' -> Some (Char.code c - Char.code 'a' + 10)
      | 'A' .. 'F' -> Some (Char.code c - Char.code 'A' + 10)
      | _ -> None
    in
    let rec go k acc =
      if k = 4 then Some acc
      else if i + k >= n then None
      else
        match digit req.[i + k] with
        | Some d -> go (k + 1) ((acc lsl 4) lor d)
        | None -> None
    in
    go 0 0
  in
  (* Read one string literal. [i] points inside it, just after the opening
     quote; the answer carries the position just after the closing one, so that
     the scan can go looking for the next argument. *)
  let read_string i =
    let buf = Buffer.create 32 in
    let rec scan i =
      if i >= n then None
      else
        match req.[i] with
        | '"' -> Some (Buffer.contents buf, i + 1)
        | '\\' when i + 1 < n -> escape (i + 1)
        | c ->
            Buffer.add_char buf c;
            scan (i + 1)
    and escape i =
      match req.[i] with
      | ('"' | '\\' | '/') as c ->
          Buffer.add_char buf c;
          scan (i + 1)
      | 'b' -> Buffer.add_char buf '\b'; scan (i + 1)
      | 'f' -> Buffer.add_char buf '\012'; scan (i + 1)
      | 'n' -> Buffer.add_char buf '\n'; scan (i + 1)
      | 'r' -> Buffer.add_char buf '\r'; scan (i + 1)
      | 't' -> Buffer.add_char buf '\t'; scan (i + 1)
      | 'u' -> unicode (i + 1)
      | _ -> None
    (* A code point above the BMP is sent as a surrogate pair, so the two halves
       have to be recombined before being encoded as UTF-8. *)
    and unicode i =
      match hex4 i with
      | None -> None
      | Some hi when hi >= 0xd800 && hi <= 0xdbff ->
          if i + 6 <= n && req.[i + 4] = '\\' && req.[i + 5] = 'u' then
            match hex4 (i + 6) with
            | Some lo when lo >= 0xdc00 && lo <= 0xdfff ->
                let u = 0x10000 + ((hi - 0xd800) lsl 10) + (lo - 0xdc00) in
                Buffer.add_utf_8_uchar buf (Uchar.of_int u);
                scan (i + 10)
            | _ -> None
          else None
      | Some lone when lone >= 0xdc00 && lone <= 0xdfff -> None
      | Some c ->
          Buffer.add_utf_8_uchar buf (Uchar.of_int c);
          scan (i + 4)
    in
    scan i
  in
  (* Whatever sits between two literals — the commas, the brackets, a numeric
     argument — is not a quote, so walking the request one character at a time
     is enough to find where the next one starts. *)
  let rec collect i acc =
    if i >= n then Some (List.rev acc)
    else if req.[i] = '"' then
      match read_string (i + 1) with
      | None -> None
      | Some (s, next) -> collect next (s :: acc)
    else collect (i + 1) acc
  in
  collect 0 []

(* The first string argument of a request, for the bindings that take exactly
   one. A request holding no string at all (["[]"], ["[42]"]) has none. *)
let json_string_arg req =
  match json_string_args req with Some (s :: _) -> Some s | _ -> None

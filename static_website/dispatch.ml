open Lwt
open Printf
open V1_LWT

module Main (C:CONSOLE) (FS:KV_RO) (STACK: V1_LWT.STACKV4) = struct

  module Http1_channel = Channel.Make(STACK.TCPV4)
  module Http1 = HTTP.Make(Http1_channel)
  module S = Http1.Server

  let start c fs stack =

    let read_fs name =
      FS.size fs name
      >>= function
      | `Error (FS.Unknown_key _) -> fail (Failure ("read " ^ name))
      | `Ok size ->
        FS.read fs name 0 (Int64.to_int size)
        >>= function
        | `Error (FS.Unknown_key _) -> fail (Failure ("read " ^ name))
        | `Ok bufs -> return (Cstruct.copyv bufs)
    in

    (* Split a URI into a list of path segments *)
    let split_path uri =
      let path = Uri.path uri in
      let rec aux = function
        | [] | [""] -> []
        | hd::tl -> hd :: aux tl
      in
      Printf.printf "[DEBUG] URI=%s\n" path;
      List.filter (fun e -> e <> "")
        (aux (Re_str.(split_delim (regexp_string "/") path)))
    in

    (* dispatch non-file URLs *)
    let rec dispatcher req_body = function
      | [] | [""] -> dispatcher req_body ["index.html"] 
      | segments ->
        let path = String.concat "/" segments in
        try_lwt
          read_fs path
          >>= fun body ->
          Printf.printf "[DEBUG] Start respond_string w/ size=%d\n" (String.length body);
          S.respond_string ~status:`OK ~body ()
        with exn ->
          let cmd = String.sub path 0 3 in
          let sexp str =
            Re_str.(global_replace (regexp_string "%20") " " (replace_first (regexp_string cmd) "" str)) in
          match cmd with
          | "GET" -> begin
            match STACK.get_state stack (sexp path) with
            | Some body -> S.respond_string ~status:`OK ~body ()
            | None -> S.respond_not_found ()
          end
          | "SET" -> begin
            lwt str = Cohttp_lwt_body.to_string req_body in
            match STACK.set_state stack (sexp str) with
            | Some body -> S.respond_string ~status:`OK ~body ()
            | None -> S.respond_not_found ()
          end
          | _ -> S.respond_not_found ()
    in

    (* HTTP callback *)
    let callback conn_id request body =
      let uri = S.Request.uri request in
      dispatcher body (split_path uri)
    in
    let conn_closed conn_id () =
      let cid = Cohttp.Connection.to_string conn_id in
      C.log c (Printf.sprintf "conn %s closed" cid)
    in
    let accept spec flow =
      let chan = Http1_channel.create flow in
      Http1.Server_core.callback spec chan chan
    in
    let listen spec =
      STACK.listen_tcpv4 ~port:80 stack (accept spec);
      STACK.listen stack 
    in
    C.log c "[DEBUG] Start listening on port 80...";
    listen { S.callback; conn_closed }

end

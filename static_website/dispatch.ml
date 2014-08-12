open Lwt
open Printf
open V1_LWT

module Main (C:CONSOLE) (FS:KV_RO) (STACK: V1_LWT.STACKV4) = struct

  module Http1_channel = Channel.Make(STACK.TCPV4)
  module Http1 = HTTP.Make(Http1_channel)
  module S = Http1.Server

  type conntbl = (string, (Http1_channel.t option * Http1_channel.t option * string)) Hashtbl.t

  let start c fs stack =

    let conns : conntbl = Hashtbl.create 10 in
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

    let find_channels flow_id =
      try
        match Hashtbl.find conns flow_id with
        | (Some ic, Some oc, _) -> (Some ic, Some oc)
        | _ -> (None, None)
      with Not_found -> (None, None)
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
          (* XXX: the following get/set state part will be provided as simple APIs
           *      but now inlined for testing *)
          let cmd = String.sub path 0 3 in
          let sexp str =
            (* trim cmd out and replace %20 with a space *)
            Re_str.(global_replace (regexp_string "%20") " " (replace_first (regexp_string cmd) "" str)) in
          let state_delim = "###" in  (* XXX *)
          match cmd with  (* first 3 chars in file path as a command *)
          | "GET" -> begin
            let flow_id = sexp path in
            (* get tcp state first *)
            match STACK.get_state stack flow_id with
            | Some stack_state -> begin
              (* if flow exists, get channel state.
               * ongoing connection must be found from conns hashtbl *)
              match find_channels flow_id with
              | (Some ic, Some oc) ->  (* likely *)
                let chan_state = Http1_channel.get_state ic oc in
                let body = stack_state ^ state_delim ^ chan_state in
                S.respond_string ~status:`OK ~body ()
              | _ -> S.respond_not_found ()
            end
            | None -> S.respond_not_found ()
          end
          | "SET" -> begin
            (* states to be set is delivered via POST due to long string *)
            lwt state = Cohttp_lwt_body.to_string req_body in
            match Re_str.(split (regexp_string state_delim) state) with
            (* instead of extracting flow_id from stack_state, just let
             * state setter to prepend flow_id *)
            | [flow_id; stack_state; chan_state] -> begin
              (* channels are not created at this moment, so keep it for restore *)
              Hashtbl.replace conns flow_id (None, None, chan_state);

              (* restore tcp state. this call invokes user-provided callback
               * ('accept' in this case) right after restoring tcp state on a
               * newly created pcb. *)
              match STACK.set_state stack (sexp stack_state) with
              | Some body -> S.respond_string ~status:`OK ~body ()
              | None -> S.respond_not_found ()
            end
            | _ -> S.respond_not_found ()
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
    let restore_chan flow_id ic oc =
      try
        match Hashtbl.find conns flow_id with
        | (None, None, chan_state) ->
            Printf.printf "[DEBUG] RESTORE CHAN: %s ...\n" (String.sub chan_state 0 80);
            Http1_channel.set_state ic oc chan_state
        | _ -> ()
      with Not_found -> ()
    in
    let accept spec flow =
      let chan = Http1_channel.create flow in
      let flow_id = STACK.TCPV4.string_of_id flow in
      (* if this flow is restored, chan should be also restored *)
      restore_chan flow_id chan chan;
      Hashtbl.replace conns flow_id (Some chan, Some chan, "");
      Http1.Server_core.callback spec chan chan
    in
    let listen spec =
      STACK.listen_tcpv4 ~port:80 stack (accept spec);
      STACK.listen stack 
    in
    C.log c "[DEBUG] Start listening on port 80...";
    listen { S.callback; conn_closed }

end

(*
 * Copyright (c) 2014-2015 Magnus Skjegstad <magnus@skjegstad.com>
 * Copyright (c) 2014-2016 Masoud Koleini <masoud.koleini@nottingham.ac.uk>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Cmdliner
open Irmin_unix

module Store = Irmin_unix.Irmin_http.Make(Irmin.Contents.String)(Irmin.Ref.String)(Irmin.Hash.SHA1)
module View = Irmin.View (Store)
module I = Irmin_unix.Irmin_http.Make(Irmin.Contents.String)(Irmin.Ref.String)(Irmin.Hash.SHA1)

let unwatch_table : (string, unit -> unit Lwt.t) Hashtbl.t = Hashtbl.create 100 (* max number of machines in the datacenter *)

let add_backend_support_msg =
    "Install `libvirt`, `xen-api-client` (xapi) or `xenctrl` (libxl) with opam to add the corresponding backend."

let info =
  let doc =
    "Just-In-Time Summoning of Unikernels. Jitsu is a forwarding DNS server \
     that automatically boots unikernels when their domain is requested. \
     The DNS response is sent to the client after the unikernel has started, \
     enabling the client to use unmodified software to communicate with \
     unikernels that are started on demand. If no DNS requests are received \
     for the unikernel within a given timeout period, the unikernel is automatically \
     stopped." in
  let list_options l =
    List.map (fun x ->
        let (k,v) = x in
        `I ((Printf.sprintf "$(b,%s)" k), v)) l in
  let common_options =
    [ ("response_delay", "Override default DNS query response delay for this unikernel. See also -d.") ;
      ("wait_for_key", "Wait for this key to appear in Xenstore before responding to the DNS query. Sleeps for [response_delay] after the key appears. The key should be relative to /local/domain/[domid]/.") ;
      ("use_synjitsu", "Enable Synjitsu for this domain if not 0 or absent (requires Synjitsu support enabled)") ] in
  let backend_options name = 
      match Vm_backends.lookup name with
      | None -> [] (* Only include options if compiled in *)
      | Some (module M : Backends.VM_BACKEND)-> 
                  [`S (Printf.sprintf "%s CONFIGURATION" (String.uppercase name)) ] @ 
                  (list_options M.get_config_option_list)
  in
  let man =
    [ `S "BACKENDS" ;
      `P "Jitsu can use different backends to control unikernel VMs (or processes). Support for libvirt, xapi and libxl will \
          be enabled if the libraries are available. Note that Xapi and libxl support are less tested and should be considered \
          experimental." ;
      `P add_backend_support_msg ] @
    [ `S "COMMON CONFIGURATION" ] @ (list_options common_options) @
    backend_options "libvirt" @
    backend_options "xapi" @
    backend_options "libxl" @
    [ `S "EXAMPLES";
      `P "$(b,jitsu -c xen:/// -f 8.8.8.8 dns=mirage.io,ip=10.0.0.1,vm=mirage-www)" ;
      `P "Connect to Xen via libvirt. Start unikernel $(b,mirage-www) on requests for $(b,mirage.io) and \
          return IP $(b,10.0.0.1) in DNS. Forward unknown requests to \
          $(b,8.8.8.8).";
      `P "$(b,jitsu -c vbox:///session -m suspend dns=home.local,ip=192.168.0.1,name=ubuntu -t 60)";
      `P "Connect to Virtualbox. Start VM $(b,ubuntu) on requests for $(b,home.local) \
          and return IP $(b,192.168.0.1). Forward unknown requests to system default. \
          Expired VMs are $(b,suspended) after $(b,120) seconds (2 x DNS ttl).";
      `S "AUTHORS";
      `P "Magnus Skjegstad <magnus@skjegstad.com>" ;
      `S "BUGS";
      `P "Submit bug reports to http://github.com/mirage/jitsu";] in
  Term.info "jitsu" ~version:Jitsu_version.current ~doc ~man

let bindaddr =
  let doc = "Bind local DNS server to interface with this IP" in
  Arg.(value & opt string "127.0.0.1" & info ["b"; "bind"] ~docv:"ADDR" ~doc)

let bindport =
  let doc = "UDP port to listen for DNS queries" in
  Arg.(value & opt int 53 & info ["l"; "listen"] ~docv:"PORT" ~doc)

let connstr =
  let doc =
    "Libvirt or Xapi connection string (e.g. xen+ssh://x.x.x.x/system or vbox:///session)"
  in
  Arg.(value & opt string "xen:///" & info ["c"; "connect"] ~docv:"CONNECT" ~doc)

let forwarder =
  let doc =
    "IP address of DNS server queries should be forwarded to if no local match \
     is found. Defaults to system default (/etc/resolv.conf) if not specified. \
     Set to 0.0.0.0 to disable forwarding."
  in
  Arg.(value & opt string "" & info ["f" ; "forwarder"] ~docv:"ADDR" ~doc)

let forwardport =
  let doc = "UDP port to forward DNS queries to" in
  Arg.(value & opt int 53 & info ["p"; "port"] ~docv:"PORT" ~doc)

let response_delay =
  let doc =
    "Time to wait in seconds before responding to a DNS query after the local \
     VM has started. This delay gives the VM time to open up the necessary TCP \
     ports etc. Setting this value too low can result in long delays on the \
     first TCP request to the VM." in
  Arg.(value & opt float 0.1 & info ["d" ; "delay" ] ~docv:"SECONDS" ~doc)

let map_domain =
  let doc =
    "Unikernel configuration. Maps DNS and IP to a unikernel VM. Configuration \
     options are passed as keys and values in the form \"key1=value1,key2=value2...\". \
     A configuration string must be specified for each \
     unikernel Jitsu should control. \
     Required keys are $(b,name), $(b,dns) and $(b,ip). \
     Depending on the selected virtualization backend, additional keys may be supported. \
     See full list of available keys below." in
  Arg.(non_empty & pos_all (array ~sep:',' (t2 ~sep:'=' string string)) [] & info []
         ~docv:"CONFIG" ~doc)

let ttl =
  let doc =
    "DNS TTL in seconds. The TTL determines how long the clients may cache our \
     DNS response. VMs are terminated after no DNS requests have been received \
     for TTL*2 seconds." in
  Arg.(value & opt int 60 & info ["t" ; "ttl" ] ~docv:"SECONDS" ~doc)

let vm_stop_mode =
  let doc =
    "How to stop running VMs after timeout. Valid options are $(b,suspend), \
     $(b,destroy) and $(b,shutdown). Suspended VMs are generally faster to \
     resume, but require resources to store state. Note that MirageOS \
     suspend/resume is currently not supported on ARM." in
  Arg.(value & opt (enum [("destroy" , Vm_stop_mode.Destroy);
                          ("suspend" , Vm_stop_mode.Suspend);
                          ("shutdown", Vm_stop_mode.Shutdown)])
         Vm_stop_mode.Destroy & info ["m" ; "mode" ] ~docv:"MODE" ~doc)

let synjitsu_domain_uuid =
  let doc =
    "UUID of a running Synjitsu compatible unikernel. When specified, \
     Jitsu will attempt to connect to a Synjitsu unikernel over Vchan on port 'synjitsu' \
     and send notifications with updates on MAC- and IP-addresses of booted \
     unikernels. This allows Synjitsu to send gratuitous ARP on behalf of \
     booting unikernels and to cache incoming SYN packets until they are \
     ready to receive them. This feature is $(b,experimental) and requires a patched \
     MirageOS TCP/IP stack."  in
  Arg.(value & opt (some string) None & info ["synjitsu"] ~docv:"UUID" ~doc)

let persistdb =
  let doc =
    "Store the Irmin database in the specified path. The default is to store the database in memory only. \
     Note that modifying this database while Jitsu is running is currently unsupported and may crash Jitsu
     or have other unexpected results." in
  Arg.(value & opt (some string) None & info [ "persistdb" ] ~docv:"path" ~doc)

let log m =
  Printf.fprintf stdout "\027[32m%s\n%!\027[m" m

let or_abort f =
  try f () with
  | Failure m -> (Printf.fprintf stderr "Fatal error: %s" m); exit 1

let or_warn msg f =
  try f () with
  | Failure m -> (log (Printf.sprintf "Warning: %s\nReceived exception: %s" msg m)); ()
  | e -> (log (Printf.sprintf "Warning: Unhandled exception: %s" (Printexc.to_string e))); ()

let or_warn_lwt msg f =
  try_lwt f () with
  | Failure m -> (log (Printf.sprintf "Warning: %s\nReceived exception: %s" msg m)); Lwt.return_unit
  | e -> (log (Printf.sprintf "Warning: Unhandled exception: %s" (Printexc.to_string e))); Lwt.return_unit

let backend =
  let type_if_exists n t =
     match Vm_backends.lookup n with
     | None -> []
     | Some _ -> [(n, t)]
  in
  let backends =
      type_if_exists "libvirt" `Libvirt @
      type_if_exists "libxl" `Libxl @
      type_if_exists "xapi" `Xapi
  in
  let backend_names = 
      String.concat ", " (List.map (fun t -> let n, _ = t in n) backends)
  in
  let default = 
      try
          let _, t = List.hd backends in
          t
      with
      | Failure _ -> raise (Failure (Printf.sprintf "No backend support compiled in. %s" add_backend_support_msg))
  in
  let doc =
    (Printf.sprintf 
     "Which backend to use. This version is compiled with support for: $(b,%s)." backend_names) in
  Arg.(value & opt (enum backends) default & info ["x" ; "backend" ] ~docv:"BACKEND" ~doc)


let jitsu backend connstr bindaddr bindport forwarder forwardport response_delay
    map_domain ttl vm_stop_mode synjitsu_domain_uuid persistdb =
  let (module Vm_backend : Backends.VM_BACKEND) =
    let lookup_or_fail name =
        match Vm_backends.lookup name with
        | None -> raise (Failure (Printf.sprintf "Support for backend '%s' not enabled in this version of jitsu. Install the backend with opam and try again." name))
        | Some (module M : Backends.VM_BACKEND) -> (module M : Backends.VM_BACKEND)
    in
    match backend with
    | `Libvirt -> lookup_or_fail "libvirt"
    | `Xapi -> lookup_or_fail "xapi"
    | `Libxl -> lookup_or_fail "libxl"
  in
  let (module Storage_backend : Backends.STORAGE_BACKEND) = 
    match persistdb with
    | None -> (module Irmin_backend.Make(Irmin_unix.Irmin_git.Memory))
    | Some _ -> (module Irmin_backend.Make(Irmin_unix.Irmin_git.FS))
  in
  let module DC = Datacenter.Make(Storage_backend) in
  let module Jitsu = Jitsu.Make(Vm_backend)(Storage_backend) in
  let rec maintenance_thread t timeout =
    Lwt_unix.sleep timeout >>= fun () ->
    Printf.printf "%s%!" ".";
    or_warn_lwt "Unable to stop expired VMs" (fun () -> Jitsu.stop_expired_vms t) >>= fun () ->
    maintenance_thread t timeout;
  in
  Lwt.async_exception_hook := (fun exn -> log (Printf.sprintf "Exception in async thread: %s" (Printexc.to_string exn)));
  Lwt_main.run (
    lwt datacenter = DC.create () in
    ((match forwarder with
        | "" -> Dns_resolver_unix.create () >>= fun r -> (* use resolv.conf *)
          Lwt.return (Some r)
        | "0.0.0.0" -> Lwt.return None
        | _  -> let forwardip = Ipaddr.of_string_exn forwarder in (* use ip from forwarder *)
          let servers = [(forwardip,forwardport)] in
          let config = `Static ( servers , [""] ) in
          Dns_resolver_unix.create ~config:config () >>= fun r ->
          Lwt.return (Some r)
      )
     >>= fun forward_resolver ->
     let connstr = Uri.of_string connstr in
     let synjitsu =
       match synjitsu_domain_uuid with
       | Some s -> Uuidm.of_string s
       | None -> None
     in
     Vm_backend.connect ~connstr () >>= fun r ->
     match r with
     | `Error e -> raise (Failure (Printf.sprintf "Unable to connect to backend: %s" (Jitsu.string_of_error e)))
     | `Ok backend_t ->
       or_abort (fun () -> Jitsu.create backend_t log forward_resolver ~synjitsu ~persistdb datacenter ()) >>= fun t ->

       let watch_remote_hosts ~storage ~host:_r_host diff =
         let process_response () =
           log "Response detected";
           Storage_backend.get_response storage ~requestor:(List.hd Dc_params.hosts_names) >>= function
           | Rpc.Enum response when response <> [] ->
             (* read response params *)
             return ()
           | _ -> (* raise (Failure "Empty or non well-formed response") *)
             return ()
         in
         match diff with
         | `Added _  | `Updated _ -> process_response ()
         | `Removed _ -> return ()
       in
       let process_tags repo _tag diff =
         let process_command key value =
           match (List.nth key 1) with
           | "request" -> begin
             let requestor  = List.nth key 0 in
             match Dc_params.rpc_of_string value with
             | Rpc.Enum action when action <> [] ->
               let params = List.tl action in begin
               match Rpc.string_of_rpc (List.hd action) with
               | "add_vm" -> begin
                 try
                   Jitsu.add_replica t ~requestor ~params
                 with _exn ->
                  Printexc.print_backtrace stdout;
                  return ()
               end
               | "dis_vm" -> Jitsu.dis_replica t ~requestor
               | "del_vm" -> begin
                 try
                   Jitsu.del_replica t ~requestor
                 with _exn ->
                  Printexc.print_backtrace stdout;
                  return ()
               end
               | "def_vm" ->
                 let kernel  = Uri.of_string (Rpc.string_of_rpc (List.nth params 0)) in
                 let mac = Macaddr.of_string_exn (Rpc.string_of_rpc (List.nth params 1)) in
                 Vm_backend.define_vm backend_t ~name_label:requestor ~mAC:mac ~pV_kernel:kernel >>=
                 fun _ -> return ()
               | act ->
                 return (log (Printf.sprintf "requested action (%s) is not valid" act))
               end
             | _ -> raise (Failure (Printf.sprintf "Empty or non well-formed request: %s\n" value))
           end
           | _ -> return (log (Printf.sprintf "key: %s added: %s" (String.concat "/" key) value))
         in
         let process_diff view_p h =
           (* Store.Repo.create config >>= Store.master task >>= fun s -> *)
           lwt s = Store.of_commit_id task h repo in
           lwt view = View.of_path (s "of-path views") ["jitsu"; "request";] in
           View.diff view_p view >>= fun views ->
           let _ =
           Lwt_list.iter_s (fun (k, v) ->
             match v with
             | `Added v -> process_command k v
             | `Updated (_, v) -> process_command k v
             | `Removed v -> return (log (Printf.sprintf "key: %s removed: %s" (String.concat " " k) v))
             ) views
           in
             return ()
          in
          match diff with
          | `Added h ->
              lwt view_p = View.empty () in
              process_diff view_p h
          | `Updated (h1, h2) ->
              lwt s = Store.of_commit_id task h1 repo in
              lwt view_p = View.of_path (s "of-path views") ["jitsu"; "request";] in
              process_diff view_p h2
          | `Removed _ -> return (log "keys removed")
       in
       let storage = Jitsu.get_storage t in
       let ir_conn = Storage_backend.get_irmin_conn storage in
       Lwt_list.iter_s (fun h ->
         let ir_conn = Storage_backend.get_irmin_conn (h.DC.irmin_store) in
         let path = [ "jitsu" ; "request"; (List.hd Dc_params.hosts_names) ; "response"; ] in
         I.update (ir_conn "Add response") path "[]" >>
         I.watch_key (ir_conn "jitsu") path
           (watch_remote_hosts ~storage:(h.DC.irmin_store) ~host:h) >>= fun watch ->
             Hashtbl.add unwatch_table h.DC.name watch;
             return ()
         ) (DC.get_all_remote_hosts datacenter) >>
         let repo = (I.repo (ir_conn "jitsu")) in
         I.Repo.watch_branches repo (process_tags repo) >>= fun _ ->

        let rec dc_monitoring_thread timeout =
          Storage_backend.get_host_list (Jitsu.get_storage t) >>= fun keepalives ->
          let local_host = DC.get_local_host (Jitsu.get_datacenter t) in
          let datacenter = DC.get_all_remote_hosts (Jitsu.get_datacenter t) in
          (** create a list of new alive hosts in the datacenter *)
          lwt new_hosts =
            let rec find x lst =
              match lst with
              | [] -> raise (Failure "keepalive doesn't exist on the list")
              | h::t -> if h = x then 0 else 1 + find x t
            in
            let nhs =
              List.filter (fun (n, tm) ->
                log (Printf.sprintf "keepalives: %s, size of datacenter: %d\n" n (List.length datacenter));
                match tm with
                | None -> false
                | Some t -> ( not (List.exists (fun h -> h.DC.name = n) datacenter) && List.exists (fun name -> name = n) Dc_params.hosts_names ) && (Unix.time () -. t) <= 10.0
              ) keepalives in
            Lwt_list.filter_map_s (fun (name, _) ->
              let idx = find name Dc_params.hosts_names in
              let ip = List.nth Dc_params.hosts_ips idx in
              let irmin = List.nth Dc_params.hosts_irmins idx in
              DC.create_host name ip irmin >>= function
              | Some host ->
                (* add irmin watch *)
                let ir_conn = Storage_backend.get_irmin_conn host.DC.irmin_store in
                let path = [ "jitsu" ; "request"; (List.hd Dc_params.hosts_names) ; "response"; ] in
                I.watch_key (ir_conn "jitsu") path
                 (watch_remote_hosts ~storage:(host.DC.irmin_store) ~host) >>= fun watch ->
                Hashtbl.add unwatch_table host.DC.name watch;
                return (Some host)
              | None -> return None
                ) nhs
          in
          log (Printf.sprintf "number of new hosts: %d!\n" (List.length new_hosts));
          (** create a list of hosts that didn't announce they aliveness *)
          let (dead_hosts, alive_hosts) =
            List.partition (fun h ->
              List.for_all (fun (n, _) -> h.DC.name <> n) keepalives ||
              List.exists (fun (n, tm) -> if h.DC.name = n then
                match tm with
                | None -> true
                | Some t -> (Unix.time () -. t) > 7.0
                else
                  false) keepalives
              ) datacenter in
          log (Printf.sprintf "number of dead hosts: %d!\n" (List.length dead_hosts));
          lwt all_alives = (* all the datacenter machines their irmin is accessible *)
            Lwt_list.filter_map_s (fun h ->
              try_lwt
                let ir_conn = Storage_backend.get_irmin_conn (h.DC.irmin_store) in
                let path = [ "jitsu" ; "datacenter"; (List.hd Dc_params.hosts_names) ; ] in
                I.update (ir_conn "Update keep-alive") path (string_of_float (Unix.time ())) >>
                return (Some h)
              with _ -> return None
            ) (alive_hosts @ new_hosts)
          in
          log (Printf.sprintf "number of alives: %d!\n" (List.length all_alives));
          (* unwatch dead hosts *)
          lwt () =
            Lwt_list.iter_s (fun h ->
              let ir_conn = Storage_backend.get_irmin_conn h.DC.irmin_store in
              let w = Hashtbl.find unwatch_table h.DC.name in
              (* TODO: I.unwatch (ir_conn "jitsu") w >>= fun () -> *)
              let _ = Hashtbl.remove unwatch_table h.DC.name in
              return ()
              ) dead_hosts
          in
          let () = Jitsu.update_datacenter t (local_host::all_alives) in
          Lwt_unix.sleep timeout >>= fun () ->
          dc_monitoring_thread timeout;
        in

      Jitsu.startup_check t >>= fun _ ->

      Lwt.pick [(
           (* main thread, DNS server *)
           let add_with_config config_array = (
             let vm_config = (Hashtbl.create (Array.length config_array)) in
             (Array.iter (fun (k,v) -> Hashtbl.add vm_config k v) config_array); (* Use .add to support multiple values per parameter name *)
             let dns_names = Options.get_dns_name_list vm_config "dns" in
             let vm_name = Options.get_str vm_config "name" in
             let vm_ip = Options.get_ipaddr vm_config "ip" in
             let response_delay =  (* override default response_delay if key set in config *)
               match (Options.get_float vm_config "response_delay") with
               | `Error _ -> response_delay
               | `Ok d -> d
             in
             let use_synjitsu =
               match (Options.get_bool vm_config "use_synjitsu"), synjitsu with
               | `Error _, _
               | `Ok _, None -> false (* default to false if use_synjitsu is not set or synjitsu is not enabled *)
               | `Ok v, Some _ -> v
             in
             let wait_for_key =
               match Options.get_str vm_config "wait_for_key" with
               | `Error _ -> None
               | `Ok v -> Some v
             in
             match dns_names, vm_name, vm_ip with
             | `Error e, _, _
             | _, `Error e, _
             | _, _, `Error e -> raise (Failure (Options.string_of_error e))
             | `Ok dns_names, `Ok vm_name, `Ok vm_ip -> begin
                 match (Ipaddr.to_v4 vm_ip) with
                 | None -> raise (Failure (Printf.sprintf "Only IPv4 is supported. %s is not a valid IPv4 address." (Ipaddr.to_string vm_ip)))
                 | Some vm_ip -> begin
                     List.iter (fun dns_name ->
                         log (Printf.sprintf "Adding domain '%s' for VM '%s' with ip %s" (Dns.Name.to_string dns_name) vm_name (Ipaddr.V4.to_string vm_ip)))
                       dns_names;
                     or_abort (fun () -> Jitsu.add_vm t ~dns_names:dns_names ~vm_ip ~vm_stop_mode ~response_delay ~wait_for_key ~use_synjitsu ~dns_ttl:ttl ~vm_config)
                   end
               end
           ) in
           Lwt_list.iter_s add_with_config map_domain >>= fun () ->
           Jitsu.output_stats t () >>= fun () ->
           log (Printf.sprintf "Starting DNS server on %s:%d..." bindaddr bindport);
           try_lwt
             let processor = ((Dns_server.processor_of_process (Jitsu.process t))
                              :> (module Dns_server.PROCESSOR)) in
             Dns_server_unix.serve_with_processor ~address:bindaddr ~port:bindport ~processor
           with
           | e -> log (Printf.sprintf "DNS thread exited unexpectedly with exception: %s" (Printexc.to_string e)); Lwt.return_unit
             >>= fun () ->
             log "DNS server no longer running. Exiting...";
             Lwt.return_unit);

          (* maintenance thread, delay in seconds *)
          (try_lwt
             maintenance_thread t 5.0
           with
           | e -> log (Printf.sprintf "Maintenance thread exited unexpectedly with exception: %s" (Printexc.to_string e)); Lwt.return_unit
             >>= fun () ->
             log "Maintenance thread no longer running. Exiting...";
             Lwt.return_unit);
          (try_lwt
             dc_monitoring_thread 5.0;
           with
           | e -> log (Printf.sprintf "DC monitoring thread exited unexpectedly with exception: %s" (Printexc.to_string e)); Lwt.return_unit
             >>= fun () ->
             log "DC monitoring thread no longer running. Exiting...";
             Lwt.return_unit);
            ]);
  )

let jitsu_t =
  Term.(pure jitsu $ backend $ connstr $ bindaddr $ bindport $ forwarder $ forwardport
        $ response_delay $ map_domain $ ttl $ vm_stop_mode $ synjitsu_domain_uuid $ persistdb )

let () =
  match Term.eval (jitsu_t, info) with
  | `Error _ -> exit 1
  | _ -> exit 0

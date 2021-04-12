(* returns reset function *)
let enable_raw_mode () =
  let open Unix in
  let termios = tcgetattr stdin in
  tcsetattr stdin TCSAFLUSH
    { termios with
      c_ixon = false;
      c_icrnl = false;
      c_echo = false;
      c_icanon = false;
      c_isig = false;
    };
  (fun () -> tcsetattr stdin TCSAFLUSH termios)

let get_char () =
  try
    Some (input_char stdin)
  with End_of_file -> None

let () =
  let rec loop () =
    match get_char () with
    | None -> ()
    | Some 'q' -> ()
    | Some c -> Printf.printf "%d (%c)\n%!" (Char.code c) c; loop ()
  in
  let disable_raw_mode = enable_raw_mode () in
  Fun.protect (fun () ->
    loop ()
  ) ~finally:(fun () -> disable_raw_mode ())

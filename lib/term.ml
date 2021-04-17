open Printf

let kilo_version = "0.1"

let with_raw_mode fn =
  let open Unix in
  let termios = tcgetattr stdin in
  tcsetattr stdin TCSAFLUSH
  (* how to turn off IEXTEN ? *)
    { termios with
      c_brkint = false;
      c_inpck = false;
      c_istrip = false;
      c_ixon = false;
      c_icrnl = false;
      c_opost = false;
      c_echo = false;
      c_icanon = false;
      c_isig = false;
      c_csize = 8;
      c_vmin = 0;
      c_vtime = 1;
    };
  Fun.protect fn ~finally:(fun () -> tcsetattr stdin TCSAFLUSH termios)

module Escape_command = struct
  let clear_screen = "\x1b[2J"
  let cursor_topleft = "\x1b[H"
  let hide_cursor = "\x1b[?25l"
  let show_cursor = "\x1b[?25h"
  let erase_right_of_cursor = "\x1b[K"
  (* y and x are indexes that start from 0 *)
  let move_cursor y x = sprintf "\x1b[%d;%dH" (y+1) (x+1)
end

let write = output_string stdout
let flush () = flush stdout

let ctrl c =
  Char.chr ((Char.code c) land 0x1f)

let die msg =
  write Escape_command.clear_screen;
  write Escape_command.cursor_topleft;
  flush ();
  eprintf "%s\n" msg;
  exit 1

type key =
  | Arrow_up
  | Arrow_down
  | Arrow_right
  | Arrow_left
  | Page_up
  | Page_down
  | Home
  | End
  | Del
  | Ch of char

let read_key () =
  try
    let c = input_char stdin in
    if c = '\x1b' (* escape *) then begin
      try
        let first = input_char stdin in
        let second = input_char stdin in
        match (first, second) with
        | '[', 'A' -> Arrow_up
        | '[', 'B' -> Arrow_down
        | '[', 'C' -> Arrow_right
        | '[', 'D' -> Arrow_left
        | '[', 'H' -> Home
        | '[', 'F' -> End
        | '[', second when '0' <= second && second <= '9' ->
            let third = input_char stdin in
            (match (second, third) with
            | '1', '~' -> Home
            | '3', '~' -> Del
            | '4', '~' -> End
            | '5', '~' -> Page_up
            | '6', '~' -> Page_down
            | '7', '~' -> Home
            | '8', '~' -> End
            | _, _ -> Ch '\x1b')
        | 'O', 'H' -> Home
        | 'O', 'F' -> End
        | _, _ -> Ch '\x1b'
      with End_of_file (* time out *) -> Ch '\x1b'
    end else
      Ch c
  with End_of_file -> Ch '\000'

(* TODO: gap buffer *)
module Editor_buffer = struct
  (* buffer state should be immutable for undoing *)
  type t = {
    content: string list;
  }

  let empty = { content = [] }

  let numrows t = List.length t.content
  let numcols t y =
    match List.nth_opt t.content y with
    | None -> 0
    | Some row -> String.length row

  let append_row t row =
    { content = t.content @ [row] }

  (** get contents of buffer that starts at (`x`, `y`) and has `len` length at most.
   *  x and y are indexes from 0. *)
  let get ~y ~x ~len t =
    let row = List.nth t.content y in
    let row_len = String.length row in
    if row_len <= x then
      ""
    else
      StringLabels.sub row ~pos:x ~len:(BatInt.min len (row_len - x))
end

module Editor_config : sig
  (** global state of editor *)
  type t
  (** create new editor state *)
  val create : unit -> t option
  (** read content from file *)
  val open_file : t -> string -> t
  (** wait and process keypress *)
  val process_keypress : t -> unit
end = struct
  type t = {
    screenrows: int;
    screencols: int;
    (* cursor position *)
    mutable cx: int;
    mutable cy: int;
    (* offsets *)
    mutable rowoff: int;
    mutable coloff: int;
    (* contents *)
    buf: Editor_buffer.t;
  }

  let create () =
    let open Option_monad in
    let* rows = Terminal_size.get_rows () in
    let* cols = Terminal_size.get_columns () in
    Some { screenrows = rows;
           screencols = cols;
           cx = 0;
           cy = 0;
           rowoff = 0;
           coloff = 0;
           buf = Editor_buffer.empty;
         }

  (* shorthand for Editor_buffer.numrows *)
  let numrows t =
    Editor_buffer.numrows t.buf

  (* shorthand for Editor_buffer.numcols *)
  let numcols t =
    Editor_buffer.numcols t.buf t.cy

  let open_file t filename =
    let buf = BatFile.with_file_in filename (fun input ->
      let rec readline input buf =
        try
          readline input (Editor_buffer.append_row buf (BatIO.read_line input))
        with BatIO.No_more_input -> buf
      in
      readline input Editor_buffer.empty
    ) in
    { t with buf }

  let welcome_string width =
    let welcome = sprintf "Kilo editor -- version %s" kilo_version in
    let padding = String.make (((width - String.length welcome) / 2) - 1) ' ' in
    "~" ^ padding ^ welcome

  let draw_rows t =
    for y = 0 to t.screenrows - 1 do
      let filerow = y + t.rowoff in
      let row =
        (* text buffer *)
        if filerow < numrows t then
          Editor_buffer.get t.buf ~y:filerow ~x:t.coloff ~len:(t.screencols)
        (* welcome text *)
        else if numrows t = 0 && y = t.screenrows / 3 then welcome_string t.screencols
        (* out of buffer *)
        else "~"
      in
      write row;
      write Escape_command.erase_right_of_cursor;
      if y < t.screenrows - 1 then
        write "\r\n"
    done

  (* update rowoff if cursor is out of screen *)
  let scroll t =
    if t.cy < t.rowoff then
      t.rowoff <- t.cy
    else if t.cy >= t.rowoff + t.screenrows then begin
      t.rowoff <- t.cy - t.screenrows + 1
    end;
    if t.cx < t.coloff then
      t.coloff <- t.cx
    else if t.cx >= t.coloff + t.screencols then begin
      t.coloff <- t.cx - t.screencols + 1
    end

  let refresh_screen t =
    scroll t;
    write Escape_command.hide_cursor;
    write Escape_command.cursor_topleft;
    draw_rows t;
    write @@ Escape_command.move_cursor (t.cy - t.rowoff) (t.cx - t.coloff);
    write Escape_command.show_cursor;
    flush ()

  let move_cursor t dir =
    let cols = numcols t in
    match dir with
    | `Up -> if t.cy > 0 then t.cy <- t.cy - 1
    | `Down -> if t.cy < numrows t then t.cy <- t.cy + 1
    | `Right -> if t.cx < cols then t.cx <- t.cx + 1
    | `Left -> if t.cx > 0 then t.cx <- t.cx - 1
    | `Top -> t.cy <- 0
    | `Bottom -> t.cy <- numrows t - 1
    | `Head -> t.cx <- 0
    | `Tail -> t.cx <- cols - 1

  let rec process_keypress t =
    refresh_screen t;
    match read_key () with
    (* quit *)
    | Ch c when c = ctrl 'q' ->
        write Escape_command.clear_screen;
        write Escape_command.cursor_topleft;
        flush ()
    (* move cursor *)
    | Arrow_up | Ch 'k' -> move_cursor t `Up; process_keypress t
    | Arrow_down | Ch 'j' -> move_cursor t `Down; process_keypress t
    | Arrow_right | Ch 'l' -> move_cursor t `Right; process_keypress t
    | Arrow_left | Ch 'h' -> move_cursor t `Left; process_keypress t
    | Page_up -> move_cursor t `Top; process_keypress t
    | Page_down -> move_cursor t `Bottom; process_keypress t
    | Home -> move_cursor t `Head; process_keypress t
    | End -> move_cursor t `Tail; process_keypress t
    | _ -> process_keypress t
end

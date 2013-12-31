type ts
type state
type error
type 'a t

val error : string -> 'a t
val showerr : error -> string

val return : 'a -> 'a t
val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t

val ( >> ) : 'a t -> 'b t -> 'b t
val ( << ) : 'a t -> 'b t -> 'a t
val ( ^? ) : 'a t -> string -> 'a t
val ( <|> ) : 'a t -> 'a t -> 'a t

val many : 'a t -> 'a list t
val many1 : 'a t -> 'a list t
val sep : 'a t -> 'b t -> 'b list t
val sep1 : 'a t -> 'b t -> 'b list t
val opt : 'a t -> 'a option t

val map : ('a -> 'b) -> 'a t -> 'b t
val guard : bool -> unit t
val ( >*< ) : 'a t -> 'b t -> ('a * 'b) t

val char1 : char t
val char_when : (char -> bool) -> char t
val char : char -> char t
val keyword : string -> string t
val make_ident : (char -> bool) -> string t
val int : int t

val init_state : state
val run_ch : 'a t -> in_channel -> 'a
val run_stdin : 'a t -> 'a
val run_file : 'a t -> string -> 'a
val run_string : 'a t -> string -> 'a

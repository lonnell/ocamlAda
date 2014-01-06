let words = [
  "abort"; "abs"; "abstract"; "accept"; "access"; "aliased"; "all"; "and";
  "array"; "at"; "begin"; "body"; "case"; "constant"; "declare"; "delay";
  "delta"; "digits"; "do"; "else"; "elsif"; "end"; "entry"; "exception";
  "exit"; "for"; "function"; "generic"; "goto"; "if"; "in"; "is"; "limited";
  "loop"; "mod"; "new"; "not"; "null"; "of"; "or"; "others"; "out"; "package";
  "pragma"; "private"; "procedure"; "protected"; "raise"; "range"; "record";
  "rem"; "renames"; "requeue"; "return"; "reverse"; "select"; "separate";
  "subtype"; "tagged"; "task"; "terminate"; "then"; "type"; "use"; "until";
  "when"; "while"; "with"; "xor";
  ]

let check s =
  List.mem (String.lowercase s) words
(** SEE: http://cui.unige.ch/isi/bnf/Ada95/BNFindex.html **)
open Util
open ParserMonad
open Ast
module C = Context

let is_some = function Some _ -> true | None -> false

let sep2 s p =
  p >>= fun x -> many1 (s >> p) >>= fun xs -> return (x :: xs)
let sguard f =
  (return () |> with_state) >>= fun ((), ctx) -> guard (f ctx)
let (>>=-) p f = p >>= fun x -> return (f x)
let (>>-) p x = p >> return x
let many2 p = p >*< many1 p >>=- fun (x,xs) -> x::xs
let many3 p = p >*< many2 p >>=- fun (x,xs) -> x::xs
let optb p = opt p |> map is_some

type 'a parser = (Context.t, 'a) ParserMonad.t
let sep = ()
let todo s : 'a parser = print_endline ("-- TODO: "^s); error s

module SpecialChar = struct
  let space = char ' '
  let iso_10646_BMP = char_when ((<>) '\"')
  let quotation = char '\"'
end

let white1 =
  char_when (function | ' ' | '\t' | '\r' | '\n' -> true | _ -> false)
  >> return ()

let line_comment =
  keyword "--" >>
  many (char_when ((<>) '\n')) >>
  char '\n' >> return ()

let token p =
  many (line_comment <|> white1) >>
  p >>= fun x ->
  many (line_comment <|> white1) >>
  return x

let token_char c = token (char c) ^? (!%"token'%c'" c)

let popen = token_char '('
let pclose = token_char ')'
let comma = token_char ','
let semicolon = token_char ';'
let vbar = token_char '|'
let comsep1 p = sep1 comma p
let comsep2 p = sep2 comma p
let semsep1 p = sep1 semicolon p
let symbol s = token(keyword s)

(** {2:a A} *)

(** {3:a2 A 2. Lexical Elements} *)

let format_effector : char parser =
  char_when (function |'\x09'|'\x0b'|'\x0d'|'\x0a'|'\x0c'-> true | _ -> false)

let digit =
  char_when (function | '0'..'9' -> true | _ -> false) ^? "digit"

let identifier_letter =
  char_when (function | 'a'..'z' | 'A'..'Z' -> true | _ -> false) ^? "identletter"

let identifier_ =
  token begin
    identifier_letter >>= fun c1 ->
    many (identifier_letter <|> char '_' <|> digit) >>= fun cs ->
    return @@ string_of_chars (c1::cs)
  end

let word w =
  (identifier_ >>= fun s -> guard (s = w) ^? (!%"expected '%s' but '%s'" w s) >> return s)

let identifier =
  identifier_ >>= fun s -> guard (Reserved.check s = false) >>- s

let optb_word w = optb (word w)

let graphic_character =
  identifier_letter <|> digit
  <|> SpecialChar.space <|> SpecialChar.iso_10646_BMP

let numeral =
  sep1 (opt (token_char '_')) digit >>= (return $ string_of_chars)

let exponent =
  let plusminus =
    (token_char '+'>> return Plus) <|> (token_char '-'>> return Minus)
  in
  token_char 'E' >> opt plusminus >*< numeral

let based_literal =
  let base = numeral in
  let based_numeral =
    let extended_digit =
      digit <|> char_when (function 'A'..'F' -> true | _ -> false)
    in
    sep1 (token_char '_') extended_digit >>= (return $ string_of_chars)
  in
  base >>= fun base ->
  token_char '#' >>
  based_numeral >>= fun int ->
  opt (token_char '.' >> based_numeral) >>= fun frac ->
  token_char '#' >>
  opt exponent >>= fun expo ->
  return @@ NumBased(base, int, frac, expo)

let numeric_literal =
  let decimal_literal =
    numeral >>= fun int ->
    opt (token_char '.' >> numeral) >>= fun frac ->
    opt exponent >>= fun expo ->
    return @@ NumDecimal(int, frac, expo)
  in
  decimal_literal <|> based_literal

let character_literal =
  token begin
    char '\'' >>
    graphic_character
    << char '\''
  end

let string_literal =
  let string_element =
    (keyword "\"\"" >> return '\"')
    <|> graphic_character
  in
  token begin
    SpecialChar.quotation >>
    many string_element >>= fun cs ->
    SpecialChar.quotation >>
    return @@ string_of_chars cs
  end

let operator_symbol = string_literal

(** {3:a4 A 4. } *)

let selector_name =
  identifier <|> (character_literal |> map (String.make 1)) <|> operator_symbol
let direct_name =
  identifier <|> operator_symbol

(** {2:b B} *)
(** {3:b3 B 3. Declarations and Types}*)

let defining_identifier = identifier

let rec subtype_indication () =
  subtype_mark() >>= fun n -> opt (constraint_()) >>= fun c -> return(n,c)

and subtype_mark () = name (Some C.Submark) >>=- fun n -> SubtypeMark n

and constraint_ () =
  (range_constraint() >>= fun r -> return @@ CoRange r)
  <|> digits_constraint()
  <|> delta_constraint()
  <|> index_constraint()
  <|> discriminant_constraint()

and range_constraint () =
  word "range" >> range()

and range () =
  (range_attribute_reference() >>= fun (p,d) -> return @@ RangeAttrRef (p,d))
  <|> (simple_expression() >*< (symbol "..">>simple_expression()) >>=
       fun (x,y) ->
       return @@ Range(x,y))

and digits_constraint () =
  word"digits">> expression() >*< opt(range_constraint()) >>= fun(e,r)->
  return @@ CoDigits(e, r)

and index_constraint () =
  popen >> comsep1 (discrete_range()) << pclose >>= fun rs ->
  return @@ CoIndex rs

and discrete_range () =
  (subtype_indication() >>= fun ind -> return @@ DrSubtype ind)
  <|> (range() >>= fun r -> return @@ DrRange r)

and discriminant_constraint () =
  popen >> comsep1 (discriminant_association()) << pclose >>= fun ds ->
  return @@ CoDiscrim ds

and discriminant_association () =
  opt (sep1 vbar selector_name << symbol"=>") >*< expression()

and discrete_choice_list () = sep1 vbar (discrete_choice())

and discrete_choice () =
  (expression() >>= fun e -> return @@ DcExpr e)
  <|> (discrete_range() >>= fun r -> return @@ DcRange r)
  <|> (word "others" >> return @@ DcOthers)

(** {3:b4 B 4. Names and Expressions} *)

and name kind =
  name_ kind >>= fun n -> print_endline ("Name: "^sname n); return n
and name_ kind : name parser =
  let prefix_next prefix =
    (*indexed_component*)
    (popen >> sep1(token_char '.')(expression()) << pclose >>= fun es -> return @@ NIndexedComp(prefix, es))
    (*slice*)
    <|> (popen >> discrete_range() << pclose >>= fun dr ->
         return @@ NSlice(prefix, dr))
    (*selected_component*)
    <|> (token_char '.' >> selector_name >>= fun sel ->
         return @@ NSelectedComp(prefix, sel))
    (*attribute_reference*)
    <|> (token_char '\'' >> attribute_designator() >>= fun attr ->
         return @@ NAttrRef(prefix, attr))
  in
  let name_next prename =
    (*explicit_dereference*)
    (token_char '.' >> keyword "all" >> return @@ NExplicitDeref prename)
  in
  let submark_next submark =
    (*type_conversion*)
    (popen >> expression() >>= fun expr ->
     return @@ NTypeConv (submark, expr))
  in
  let fname_next fname =
    (*function_call*)
    actual_parameter_part() >>= fun params ->
    return @@ NFunCall (fname, Some params)
  in
  let next ctx (prename : name) =
    begin if C.check C.FuncName prename ctx then
      fname_next (FunName prename)
    else if C.check C.Submark prename ctx then
      submark_next (SubtypeMark prename)
    else
      name_next prename
    end <|>
      (guard (C.check C.Prefix prename ctx)>>
       prefix_next (Prefix prename))
  in
  let match_kind n ctx =
    match kind with
    | Some k -> C.check k n ctx
    | None -> true
  in
  let rec name_nexts ctx (prevname : name) : name parser =
    (next ctx prevname >>= fun n -> name_nexts ctx n >>= fun n' ->
     sguard(match_kind n') >> return n')
    <|> (return prevname << sguard(match_kind prevname))
  in
  ((direct_name |> with_state) >>= fun (d,ctx) -> name_nexts ctx (NDirect d)) <|> ((character_literal |>with_state) >>= fun (c,ctx) -> name_nexts ctx (NChar c))
    ^? "name"
and prefix () =
  name (Some C.Prefix) >>=- fun n -> Prefix n

and attribute_designator () : attribute parser =
  (word "Access" >> return AAccess)
  <|> (word "Delta" >> return ADelta)
  <|> (word "Digit" >> return ADigit)
  <|> (identifier >>= fun ident ->
   opt (popen >> expression() << pclose) >>= fun e ->
   return @@ AIdent(ident, e))

and range_attribute_reference () =
  let range_attribute_disignator () =
    word "Range" >> opt (popen >> expression() << pclose)
  in
  prefix() >*< (token_char '\'' >> range_attribute_disignator())

and array_aggregate () =
  let array_component_associtiation () =
    discrete_choice_list() >>= fun dcs -> symbol "=>" >>
    expression() >>= fun e -> return @@ (dcs, e)
  in
  (*positional_array_aggregate*)
  (popen >> comsep2 (expression()) >>= fun es ->
   pclose >> return @@ ArrayAgPos es)
  <|> (popen >> comsep1 (expression()) >>= fun es ->
       comma >> word "others" >> symbol "=>" >>
       expression() >>= fun oe ->
       pclose >> return @@ ArrayAgPosOthers (es,oe))
  (*named_array_aggregate*)
  <|> (popen >> comsep1 (array_component_associtiation())
       << pclose >>= fun cs ->
       return @@ ArrayAgNamed cs)

and aggregate () =
  let record_component_association () =
    let component_choice_list =
      (word "others" >> return CCLOthers)
      <|> (sep1 vbar selector_name >>= fun ns -> return @@ CCLSels ns)
    in
    opt (component_choice_list << symbol "=>") >*< expression()
  in
  let ancestor_part = expression in
  let nullrec = word"null">> word"record">> return AgNullRecord in
  (*record_aggregate*)
  (popen >> comsep1 (record_component_association())
   << pclose >>= fun cs -> return @@ AgRecord cs)
  <|> nullrec
  (*extension_aggregate*)
  <|> (popen >> ancestor_part() << word "with" >>= fun anc ->
       begin nullrec
       <|> (comsep1 (record_component_association()) >>= fun cs->
            return @@ AgExtension(anc, cs))
       end << pclose)
  (*array_aggregate*)
  <|> (array_aggregate() >>= fun aa -> return @@ AgArray aa)

and qualified_expression () =
  subtype_mark() >>= fun n ->
    (popen >> expression() << pclose >>= fun es -> return @@ QExpr(n,es))
    <|> (aggregate() >>= fun ag -> return @@ QAggr(n,ag))

and primary () =
  (numeric_literal >>= fun num -> return @@ PNum num)
  <|> (word "null" >> return @@ PNull)
  <|> (string_literal >>= fun s -> return @@ PString s)
  <|> (word "new" >>
         (subtype_indication()>>= fun ind-> return @@ PAllocator(AlSubtype ind))
         <|> (qualified_expression()>>= fun q-> return @@ PAllocator(AlQual q)))
  <|> (aggregate() >>= fun a -> return @@ PAggregate a)
  <|> (qualified_expression() >>= fun q -> return @@ PQual q)
  <|> (name None >>= fun n -> return @@ PName n)
  <|> (popen >> expression() << pclose >>= fun e ->
       return @@ PParen e)

and factor () =
  let pop = symbol "**" >> return Pow in
  (word "abs" >> primary() >>= fun p -> return @@ FAbs p)
  <|> (word "not" >> primary() >>= fun p -> return @@ FNot p)
  <|> (primary() >>= fun p -> many (pop >*< primary()) >>= fun pps ->
       return @@ FPow(p, pps))

and term () =
  let mop = (token_char '*' >> return Mult) <|> (token_char '/' >> return Div)
    <|> (word "mod" >> return Mod) <|> (word "rem" >> return Rem)
  in
  factor() >>= fun f -> many (mop >*< factor()) >>= fun mfs ->
  return @@ Term(f, mfs)

and simple_expression () =
  let plusminus =
    (token_char '+' >> return Plus) <|> (token_char '-' >> return Minus)
  in
  let aop =
    (token_char '+' >> return Add) <|> (token_char '-' >> return Sub)
    <|> (token_char '&' >> return BitAnd)
  in
  opt plusminus >>= fun pm -> term() >>= fun t -> many (aop >*< term()) >>= fun ats -> return @@ SE(pm, t, ats)
    
and relation () =
  let eop =
    (token_char '=' >> return Eq) <|> (symbol "/=" >> return Neq)
    <|> (symbol "<=" >> return Lte) <|> (token_char '<' >> return Lt)
    <|> (symbol ">=" >> return Gte) <|> (token_char '>' >> return Gt)
  in
  (simple_expression() >>= fun se -> opt(word "not") >>= fun not -> word "in">>
    begin
    (range() >>= fun range -> return @@ RInRange(is_some not, se, range))
    <|> (subtype_mark() >>= fun smark -> return @@ RInSubMark(is_some not, se, smark))
  end)
  <|> (simple_expression() >>= fun se ->
       many (eop >*< simple_expression()) >>= fun ses -> return @@ RE(se, ses))

and expression () : expression parser =
  (sep1 (word "and") (relation ()) >>= fun rs -> return @@ EAnd rs)
  <|> (sep1 (word "and" >> word "then") (relation ()) >>= fun rs ->
       return @@ EAnd rs)
  <|> (sep1 (word "or") (relation ()) >>= fun rs -> return @@ EOr rs)
  <|> (sep1 (word "or" >> word "else") (relation ()) >>= fun rs ->
       return @@ EOr rs)
  <|> (sep1 (word "xor") (relation ()) >>= fun rs -> return @@ EXor rs)

(** {3:b6 B 6. } *)

and parameter_assoc () =
  opt (selector_name << symbol "=>") >>= fun sel ->
  expression() >>= fun expr ->
  return (sel, expr)
and actual_parameter_part () =
  popen >>
  comsep1 (parameter_assoc())
  << pclose

(** {3:b13 B 13. } *)

and static_expression () = expression()
and delta_constraint() =
  word"delta">> static_expression() >*< opt(range_constraint()) >>=
  fun (e, r) -> return @@ CoDelta(e, r)
  
(** {2:bb BB} *)

(** {3:bb3 BB 3.} *)

let default_expression = expression()
let access_definition =
  word "access" >> subtype_mark() >>=- fun ty -> Access ty
let defining_identifier_list = comsep1 defining_identifier

let known_discriminant_part =
  let discriminant_specification =
    defining_identifier_list >>= fun ids -> token_char ':' >>
    (subtype_mark() >>= fun subty ->
     opt (symbol":=">> default_expression) >>=- fun e ->
     DSpecSubtype(ids, subty, e))
    <|> (access_definition >>= fun acc ->
     opt (symbol":=">> default_expression) >>=- fun e ->
     DSpecAccess(ids, acc, e))
  in
  popen>> comsep1 discriminant_specification <<pclose

let discrete_subtype_definition =
  (subtype_indication() >>=- fun ind -> DiscSubtyInd ind)
  <|> (range() >>=- fun r -> DiscSubtyRange r)

let component_definition =
  opt (word"aliased") >*< subtype_indication() >>=- fun (aliased, ind) ->
  (is_some aliased, ind)

let array_type_definition =
  let index_subtype_definition =
    subtype_mark() << word "range" << symbol "<>"
  in
  (* constrained_array_definition *)
  (word"array">> popen>> comsep1 discrete_subtype_definition >>= fun ds ->
   pclose>> word"of">> component_definition >>= fun comp ->
   return @@ ArrTypeConst(ds, comp))
  (* unconstrained_array_definition *)
  <|> (word"array">> popen>> comsep1 index_subtype_definition >>= fun is ->
    pclose>> word"of">> component_definition >>= fun comp ->
    return @@ ArrTypeUncon(is, comp))

(*===============6.*)
let parameter_profile = todo "parameter_profile"
let parameter_and_result_profile = todo "parameter_and_result_profile"
(*===============6.*)

let record_definition =
  (word "null">> word "record" >>- NullRecord)
  (*TODO*)

let access_type_definition =
  (* access_to_object_definition *)
  (word "access" >> opt (word "all" <|> word "constant") >>= fun ac ->
  subtype_indication() >>=- fun ind -> AccTyObj(ac, ind))
  (* access_to_subprogram_definition *)
  <|> (word "access">> opt (word"protected") >>= fun prot ->
    word "procedure" >> parameter_profile >>= fun prof ->
    return @@ AccTySubprogProc(is_some prot, prof))
  <|> (word "access">> opt (word"protected") >>= fun prot ->
    word "function" >> parameter_and_result_profile >>= fun p ->
    return @@ AccTySubprogFunc(is_some prot, p))

(*====================9*)
let task_definition = todo "task_definition"
let protected_definition = todo " protected_definition"
(*====================9*)

let type_declaration =
  let full_type_declaration =
    let type_definition =
      let enumeration_type_definition =
        let enumeration_literal_specification =
          (defining_identifier >>=- fun id -> ELIdent id)
          <|> (character_literal >>=- fun c -> ELChar c)
        in
        popen>> comsep1 enumeration_literal_specification <<pclose >>= fun es ->
        return @@ TDefEnum es
      in
      let integer_type_definition =
        (word"range">> simple_expression() <<symbol".." >*< simple_expression()
         >>=- fun (a,b) -> TDefInt_Range(a, b))
        <|> (word"mod">> expression() >>=- fun e -> TDefInt_Mod e)
      in
      let real_type_definition =
        let range =
          word"range">> simple_expression() <<symbol".." >*< simple_expression()
        in
        (*floating_poing_definition*)
        (word"digits">> expression() >*< opt range >>=- fun (e, r) ->
         TDefReal_Float(e, r))
        (* decimal_fixed_point_definition *)
        <|> (word"delta">> expression() >>= fun e ->
          word"digits">> expression() >>= fun d ->
          opt range >>= fun r -> return @@ TDefReal_DecFixp(e, r))
        (* ordinary_fixed_point_definition *)
        <|> (word"delta">> expression() >*< opt range >>=- fun (e, r) ->
          TDefReal_OrdFixp(e, r))
      in
      let record_type_definition =
        opt (opt (word"abstract") << word"tagged") >>= fun abs_tag ->
        opt (word"limited") >>= fun lim -> record_definition >>= fun r ->
        return @@ TDefRecord(Option.map is_some abs_tag, is_some lim, r)
      in
      let derived_type_definition =
        let record_extension_part = word"with" >> record_definition in
        opt (word "abstract") >>= fun abs ->
        word "new">> subtype_indication() >>= fun ind ->
        opt record_extension_part >>= fun r ->
        return @@ TDefDerived(is_some abs, ind, r)
      in
      enumeration_type_definition
      <|> integer_type_definition
      <|> real_type_definition
      <|> (array_type_definition >>=- fun a -> TDefArray a)
      <|> record_type_definition
      <|> (access_type_definition >>=- fun a -> TDefAcc a)
      <|> derived_type_definition
    in
    (word"type">> defining_identifier >>= fun id ->
     opt known_discriminant_part >>= fun d ->
     word "is">> type_definition >>= fun tdef -> semicolon>>
     return @@ FTDeclType(id, d, tdef))
    (* task_type_declaration *)
    <|> (word "task">> word"type">> defining_identifier >>= fun id ->
      opt known_discriminant_part >>= fun d ->
      opt (word"is">> task_definition) >>= fun task -> semicolon>>
      return @@ FTDeclTask(id, d, task))
    (* protected_type_declaration *)
    <|> (word "protected">> word"type">> defining_identifier >>= fun id ->
      opt known_discriminant_part >>= fun d ->
      word "is">> protected_definition >>= fun pdef -> semicolon>>
      return @@ FTDeclProtected(id, d, pdef))
  in
  (full_type_declaration >>=- fun ft -> TDeclFull ft)
      
  


(** {3:bb5 BB 5. Statements} *)

(** =============6*)
let procedure_name = name (Some C.ProcName) >>=- fun n -> ProcName n
(** =============6*)

let variable_name = name (Some C.Variable) >>=- fun n -> VarName n
  
let condition = expression()

let simple_statement_ : statement_elem parser =
  let pname =
    (procedure_name |> map (fun p -> PNProcName p))
    <|> (prefix() |> map (fun pre -> PNPrefix pre))
  in
  let loop_name = name None in
  (* null_statement *)
  (word "null" >> semicolon >> return StNull)
  (* assignment_statement *)
  <|> (variable_name >>= fun vname -> symbol ":=" >>
       expression() >>= fun expr -> semicolon >> return @@ StAssign(vname,expr))
  (* exit_statement *)
  <|> (word"exit">> opt loop_name >>= fun lname ->
    opt (word "when">> condition) >>= fun cond -> semicolon>>-
    StExit(lname, cond))
  (* TODO goto *)
  (* procedure_call_statement *)
  <|> (pname >>= fun n -> print_endline"proc_call_statement";
   opt (actual_parameter_part()) << token_char ';' >>= fun ps ->
   return @@ StProcCall(n, ps))
  (* return_statement *)
  <|> (word "return" >> opt (expression()) >>= fun e -> semicolon >>
       return @@ StReturn e)
  (* TODO entry *)
  (* TODO requeue *)
  (* TODO delay *)
  (* TODO abort *)
  (* TODO raise *)
  (* TODO code *)
let simple_statement : statement_elem parser =
    simple_statement_ ^? "simple_statement"

let statement_identifier = direct_name
let label =
  symbol "<<" >> statement_identifier << symbol ">>" >>= fun id ->
  return @@ Label id

(** {3:bb6 BB 6. Subprograms} *)

let function_name = name (Some C.FuncName) >>=- fun n -> FunName n

(**======from 10 **)
let parent_unit_name = name (Some C.ParentUnit) >>=- fun n -> ParentUnit n
(**======from 10 **)

let defining_program_unit_name =
  opt (parent_unit_name << token_char '.') >*< defining_identifier

let defining_designator =
  let defining_operator_symbol = operator_symbol in
  (defining_program_unit_name>>= fun(pname,id) -> return @@ DdesUname(pname,id))
  <|> (defining_operator_symbol >>= fun s -> return @@ DdesSymb s)

let mode =
  (word "in" >> word "out" >> return InOut)
  <|> (word "out" >> return Out)
  <|> (word "in" >> return In)
  <|> return NoMode

let formal_part =
  let parameter_specification =
    defining_identifier_list >>= fun ps ->
    token_char ':' >>
    begin
      (mode >*< subtype_mark() >>= fun (m,s) -> return @@ PSMode(m, s))
      <|> (access_definition >>= fun ad -> return @@ PSAccess(ad))
    end >>= fun ty ->
    opt (symbol ":=" >> default_expression) >>= fun expr ->
    return @@ (ps, ty, expr)
  in
  popen>> semsep1 parameter_specification <<pclose

let subprogram_specification =
  (word "procedure" >> defining_program_unit_name >>= fun name ->
    opt formal_part >>= fun formal -> return @@ SpecProc(name,formal))
  <|> (word "function" >> defining_designator >>= fun def ->
    opt formal_part >>= fun formal ->
    word "return" >> subtype_mark() >>= fun ret ->
    return @@ SpecFunc(def,formal,ret))

let subprogram_declaration = subprogram_specification << semicolon

let designator =
  opt (parent_unit_name << token_char '.') >*<
  (identifier <|> operator_symbol)

(** {3:bb7 BB 7. Packages} *)

(** {3:bb8 BB 8.} *)

let package_name =
  name (Some C.Package) >>=- fun n -> PackageName n
(*  name() >>= fun n -> sguard (C.check C.Package n) >>
  return @@ PackageName n*)

let use_clause =
  word "use" >>
  begin
    (comsep1 package_name >>= fun ps -> return @@ UCPackage ps)
    <|> (word "type" >> comsep1 (subtype_mark()) >>= fun ss -> return @@ UCType ss)
  end << token_char ';'
  
(** {3:bb9 BB 9.} *)

let entry_name = name (Some C.EntryName) >>=- fun n -> EntryName n

(** {3:bb10 BB 10. Program Structure and Compilation Issues} *)

let library_unit_name = name (Some C.LibraryUnit) >>=- fun n -> LibraryUnit n

let with_clause =
  word "with" >>
  comsep1 library_unit_name >>= fun lu_names ->
  token_char ';' >>
  return (lu_names)

let context_clause =
  let add_packages libnames ctx0 =
    List.map (fun (LibraryUnit n) -> n) libnames
    |> List.fold_left (fun ctx n -> C.set C.Package n ctx) ctx0
  in
  many begin
    (with_clause >>= fun wc -> update_state (add_packages wc) >>
     return @@ WithClause wc)
    <|> (use_clause |> map (fun uc -> UseClause uc))
  end

(** {3:bb12 BB 12.} *)

let generic_actual_part =
  let generic_association =
    opt (selector_name << symbol "=>") >>= fun sel ->
    begin
      (variable_name >>=- fun x -> GAsVar x)
      <|> (procedure_name >>=- fun x -> GAsProc x)
      <|> (function_name >>=- fun x -> GAsFunc x)
      <|> (entry_name >>=- fun x -> GAsEntry x)
      <|> (subtype_mark() >>=- fun x -> GAsSubtype x)
      <|> (package_name >>=- fun x -> GAsPackage x)
      <|> (expression() >>=- fun e -> GAsExpr e)
    end >>=- fun assoc -> (sel, assoc)
  in
  popen>> comsep1 generic_association <<pclose

let generic_instantiation =
  (word "package">> defining_program_unit_name >>= fun name ->
   word "is">> word "new" >> package_name >>= fun pname ->
   opt generic_actual_part >>= fun act -> semicolon >>
   return @@ GInstPackage(name,pname,act))
  <|> (word "procedure" >> defining_program_unit_name >>= fun name ->
    word "is">> word "new" >> procedure_name >>= fun pname ->
    opt generic_actual_part >>= fun act -> semicolon >>
    return @@ GInstProc(name,pname,act))
  <|> (word "function" >> defining_program_unit_name >>= fun name ->
    word "is">> word "new" >> function_name >>= fun fname ->
    opt generic_actual_part >>= fun act -> semicolon >>
    return @@ GInstFunc(name,fname,act))

(** {3:bb13 BB 13.Representation Clauses and Implementation-Dependent Features} *)

let local_name =
  ((direct_name << token_char '\'' >*< attribute_designator()) >>= fun (d,a) ->
   return @@ LocalAttr(d,a))
  <|> (direct_name >>= fun d -> return @@ LocalDirect d)
  <|> (library_unit_name >>= fun n -> return @@ LocalLib n)

let representation_clause =
  let for_ = word "for" in
  let first_subtype_local_name = direct_name in
  let enumeration_aggregate = array_aggregate() in
  let mod_clause = word"at" >> word"mod" >> static_expression() << semicolon in
  let static_simple_expression = simple_expression() in
  let first_bit = static_simple_expression in
  let last_bit  = static_simple_expression in
  let component_clause =
    local_name >>= fun lname -> word"at">> static_expression() >>= fun e ->
    word "range">> (first_bit <<symbol".." >*< last_bit) >>= fun (fst,lst) ->
    semicolon >> return @@ (lname,e,fst,lst)
  in
  (* at_clause *)
  (for_ >> direct_name >*< (word"use">>word"at">> expression() <<semicolon) >>=
   fun (n,e) -> return @@ ReprAt(n,e))
  (* record_representation_clause *)
  <|> (for_ >> first_subtype_local_name << word"use" >>= fun n ->
       word "record" >> opt mod_clause >>= fun m ->
       many component_clause >>= fun cs ->
       word "end" >> word"record" >> return @@ ReprRecord(n,m,cs))
  (* enumeration_representation_clause *)
  <|> (for_ >> first_subtype_local_name << word"use" >*< enumeration_aggregate
       << semicolon >>= fun (n,aggr) -> return @@ ReprEnum(n,aggr))
  (* attribute_definition_clause *) (*nameに'も取ってかれてうまくいかないかも*)
  <|> (for_ >> local_name >>= fun lname ->
   token_char '\'' >> attribute_designator() >>= fun attr ->
   word "use" >> expression() >>= fun e ->
   return @@ ReprAttr(lname,attr,e))

(** {2:c C} *)

(** {3:c3 C 3. } *)

let rec basic_declaration () =
  let add_type type_decl ctx =
    C.set C.Submark (NDirect (typename type_decl)) ctx
  in
  (type_declaration >>= fun td -> update_state (add_type td)>>-
    BDeclType td)
  (* subtype_declaration *)
  <|> (word "subtype" >> defining_identifier >>= fun id -> word"is">>
    subtype_indication() >>= fun ind -> semicolon>>- BDeclSubtype(id, ind))
  (* object_declaration *)
  <|> (defining_identifier_list >>= fun ids ->
    token_char ':'>> optb_word "aliased" >>= fun aliased ->
    optb_word "constant" >>= fun const ->
    (subtype_indication() >>= fun ind -> opt (symbol":=">> expression()) >>=
     fun e -> semicolon>>- BDeclObj_1(ids, aliased, const, ind, e))
    <|> (array_type_definition >>= fun arr -> opt (symbol":=">> expression())
     >>= fun e -> semicolon>>- BDeclObj_2(ids, aliased, const, arr, e)))
  (*  single_task_declaration *)
  <|> (word"task">> defining_identifier >>= fun id ->
    opt (word"is">> task_definition) >>= fun task -> semicolon>>-
    BDeclObj_3(id, task))
  (*  single_protected_declaration *)
  <|> (word"protected">> defining_identifier >>= fun id -> word"is">>
    protected_definition >>= fun prot -> semicolon>>-
    BDeclObj_4(id, prot))
  (* number_declaration *)
  <|> (defining_identifier_list >>= fun ids ->
    token_char ':'>> word"constant" >> symbol ":=">>
    expression() >>= fun e -> semicolon>> return @@ BDeclNumb (ids, e))
  (* subprogram_declaration *)
  <|> (subprogram_declaration >>=- fun sp -> BDeclSubprog sp)
  (* abstract_subprogram_declaration *)
  <|> (subprogram_specification << word"is"<<word"abstract"<<semicolon
     >>=- fun sp -> BDeclAbsSubprog sp)
  (* package_declaration *)
  <|> (package_declaration() >>=- fun pack -> BDeclPackage pack)
  (*TODO generic_declaration *)
  (* generic_instantiation *)
  <|> (generic_instantiation >>=- fun inst -> BDeclGenInst inst)
  

and basic_declarative_item () =
  (basic_declaration() >>=- fun b -> BDItemBasic b)
  <|> (representation_clause >>=- fun r -> BDItemRepr r)
  <|> (use_clause >>=- fun u -> BDItemUse u)

(** {3:c7 C 7. } *)

and package_declaration () = package_specification() <<semicolon

and package_specification () =
  word"package">> defining_program_unit_name >>= fun n ->
  word"is">> many (basic_declarative_item()) >>= fun ds ->
  opt (word"private">> many (basic_declarative_item())) >>= fun pds ->
  word"end">> opt (opt (parent_unit_name <<token_char '.') >*< identifier) >>=-
  fun uname -> (n, ds, pds, uname)

(** {3:c12 C 12. } *)

and generic_declaration () = todo "generic_declaration"

(** {2:cc CC} *)
(** {3:cc10 CC 10. Program Structure and Compilation Issues} *)

let library_unit_declaration : unit parser = todo "library_unit_declaration"

(** {2:d D} *)

(** {3:d3 D 3.} *)

let rec proper_body () =
  (subprogram_body() >>=- fun sp -> ProperSubprog sp)
  (*TODO package_body *)
  (*TODO task_body *)
  (*TODO protected_body *)

and declarative_part () =
  let body () =
    (proper_body() >>=- fun b -> BodyProper b)
    (*TODO body_stub*)
  in
  let decl_part1 = begin
    (basic_declarative_item() >>=- fun b -> DeclBasic b)
    <|> (body() >>=- fun b -> DeclBody b)
  end >>= fun decl -> update_state(C.update_for_decl decl)>>- decl
  in
  many decl_part1

(** {3:d5 D 5.} *)

and compound_statement () =
  (* if_statememtn *)
  (word "if" >>
   sep1 (word "elsif") begin
     condition >>= fun cond -> word "then" >>
     sequence_of_statements() >>= fun st ->
     return (cond, st)
   end >>= fun ss ->
   opt (word "else" >> sequence_of_statements()) >>= fun else_ ->
   word "end" >> word "if" >> semicolon >>
   return @@ StIf(ss, else_))
  (* TODO case_statement *)
  (* loop_statement *)
  <|> (opt (statement_identifier << token_char ':') >>= fun id1 ->
    (word "while">> condition >>= fun cond ->
     word "loop">> sequence_of_statements() >>= fun sts ->
     word"end">>word"loop">> opt statement_identifier >>= fun id2 ->
     semicolon>>- StLoop_While(id1, cond, sts, id2))
    <|> (word "for">> defining_identifier >>= fun defid ->
      word"in">> optb_word"reverse">>= fun rev ->
      discrete_subtype_definition >>= fun disc ->
      word "loop">> sequence_of_statements() >>= fun sts ->
      word"end">>word"loop">> opt statement_identifier >>= fun id2 ->
      semicolon>>- StLoop_For(id1, defid, rev, disc, sts, id2)))
  (* TODO block_statement *)
  (* TODO accept_statement *)
  (* TODO select_statement*)
and statement () =
  many label >>= fun labels ->
  (simple_statement <|> compound_statement()) >>= fun st ->
  return @@ (labels, st)
and sequence_of_statements () =
  many1 (statement() ^? "statement")

(** {3:d6 D 6.} *)

(**========from 11**)
and exception_handler : unit parser = todo "exception_handler"
and handled_sequence_of_statements () =
  begin
    sequence_of_statements() >>= fun stats ->
    opt (word "exception" >> many1 exception_handler) >>= fun exc ->
    return @@ HandledStatements(stats, exc)
  end ^? "handled_sequence_of_statements"
(**========from 11**)

and subprogram_body () =
  subprogram_specification >>= fun spec ->
  word "is" >>
  declarative_part() >>= fun decls ->
  word "begin" >>
  handled_sequence_of_statements() >>= fun stats ->
  word "end" >>
  opt designator >>= fun design ->
  token_char ';' >>
  return {
    spec = spec;
    declarative = decls;
    statements = stats;
    designator = design;
  }

(** {3:d7 D 7.} *)

let package_body = todo "package_body"

(** {2:dd DD} *)

(** {3:dd10 DD 10. Program Structure and Compilation Issues} *)

let subunit = todo "subunit"

let compilation =
  let compilation_unit =
    let library_item =
      let library_unit_declaration = todo "library_unit_declaration" in
      let library_unit_body =
        (subprogram_body() >>= fun subp -> return @@ LibBody_Subprog subp)
        <|> (package_body >>= fun pack -> return @@ LibBody_Package pack)
      in
      let library_unit_renaming_declaration =
        todo "library_unit_renaming_declaration"
      in
      (opt (word "private") >*< library_unit_declaration >>= fun (priv,decl) ->
       return @@ LibDecl(is_some priv, decl))
      <|> library_unit_body
      <|> (opt (word "private") >*< library_unit_renaming_declaration
             >>= fun (priv, ren) ->
           return @@ LibRenameDecl(is_some priv, ren))
    in
    context_clause >>= fun cc ->
    (library_item <|> subunit)
  in
  many1 compilation_unit


(** {2:run running} *)

let run_ch ch =
  ParserMonad.run_ch (Context.create()) (compilation) ch


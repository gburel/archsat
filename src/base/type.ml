
(* Log&Module Init *)
(* ************************************************************************ *)

let section = Util.Section.make "type"
let log i fmt = Util.debug ~section i fmt

let stack = Backtrack.Stack.create (
    Util.Section.make ~parent:section "backtrack")

module M = Map.Make(String)
module H = Backtrack.HashtblBack(struct
    type t = string
    let hash = Hashtbl.hash
    let equal = Pervasives.(=)
  end)

(* Types *)
(* ************************************************************************ *)

(* The type of potentially expected result type for parsingan expression *)
type expect =
  | Nothing
  | Type
  | Typed of Expr.ty

(* The type returned after parsing an expression. *)
type res =
  | Ttype
  | Ty of Expr.ty
  | Term of Expr.term
  | Formula of Expr.formula

(* Exceptions *)
(* ************************************************************************ *)

exception Typing_error of string * Ast.term

let _scope_err s t = raise (Typing_error (
    Format.asprintf "Scoping error: '%s' not found" s, t))
let _err t = raise (Typing_error ("Couldn't parse the expression", t))
let _expected s t = raise (Typing_error (
    Format.asprintf "Expected a %s" s, t))
let _bad_arity s n t = raise (Typing_error (
    Format.asprintf "Bad arity for operator '%s' (expected %d arguments)" s n, t))
let _type_mismatch t ty ty' ast = raise (Typing_error (
    Format.asprintf "Type Mismatch: '%a' has type %a, but an expression of type %a was expected"
      Expr.Print.term t Expr.Print.ty ty Expr.Print.ty ty', ast))
let _fo_term s t = raise (Typing_error (
    Format.asprintf "Let-bound variable '%s' is applied to terms" s, t))

(* Global Environment *)
(* ************************************************************************ *)

(* Global identifier table; stores declared types for strings.
   Hashtable from symbol names to identifiers *)
let declared_types = H.create stack
let declared_terms = H.create stack

(* Adding/finding *)
let decl_ty_cstr name c =
  try
    let c' = H.find declared_types name in
    if not (Expr.Id.equal c c') then
      log 0 "Type constructor (%a) has already been defined, skipping delcaration (%a)"
        Expr.Debug.const_ttype c' Expr.Debug.const_ttype c
  with Not_found ->
    log 1 "New type constructor : %a" Expr.Debug.const_ttype c;
    H.add declared_types name c

let decl_term name c =
  try
    let c' = H.find declared_terms name in
    if not (Expr.Id.equal c c') then
      log 0 "Function (%a) has already been defined, skipping declaration (%a)"
        Expr.Debug.const_ty c Expr.Debug.const_ty c'
  with Not_found ->
    log 1 "New constant : %a" Expr.Debug.const_ty c;
    H.add declared_terms name c

let find_global name =
  try `Ty (H.find declared_types name)
  with Not_found ->
    begin
      try
        `Term (H.find declared_terms name)
      with Not_found ->
        `Not_found
    end

(* Local Environment *)
(* ************************************************************************ *)

(* Builtin symbols, i.e symbols understood by some theories,
   but which do not have specific syntax, so end up as special
   cases of application. *)
type builtin_symbols = string -> Ast.term list ->
  [ `Ty of Expr.ty
  | `Term of Expr.term
  | `Formula of Expr.formula
  ] option

(* The local environments used for type-checking. *)
type env = {

  (* local variables (mostly quantified variables) *)
  type_vars : (Expr.ttype Expr.id)  M.t;
  term_vars : (Expr.ty Expr.id)     M.t;

  (* Bound variables (through let constructions) *)
  term_lets : Expr.term     M.t;
  prop_lets : Expr.formula  M.t;

  (* The current builtin symbols *)
  builtins : builtin_symbols;

  (* Typing options *)
  expect   : expect;
  status   : Expr.status;
}

(* Make a new empty environment *)
let empty_env
    ?(expect=Typed Expr.Ty.prop)
    ?(status=Expr.Status.hypothesis)
    builtins = {
  type_vars = M.empty;
  term_vars = M.empty;
  term_lets = M.empty;
  prop_lets = M.empty;
  builtins;
  expect; status;
}

(* Generic function for adding new variables to anenvironment.
   Tries and add a binding from [v.id_name] to [v] in [map] using [add],
   however, if a binding already exists, use [new_var] to create a
   new variable to bind to [v.id_name].
   Returns the identifiers actually bound, and the new map. *)
let add_var print new_var add map v =
  let v' =
    if M.mem Expr.(v.id_name) map then
      new_var Expr.(v.id_type)
    else
      v
  in
  log 3 "Adding binding : %s -> %a" Expr.(v.id_name) print v';
  v', add Expr.(v.id_name) v' map

(* Generate new fresh names for shadowed variables *)
let new_name pre =
  let i = ref 0 in
  (fun () -> incr i; pre ^ (string_of_int !i))

let new_ty_name = new_name "ty#"
let new_term_name = new_name "term#"

(* Add local variables to environment *)
let add_type_var env v =
  let new_var Expr.Type = Expr.Id.ttype (new_ty_name ()) in
  let v', map = add_var Expr.Debug.id_ttype new_var M.add env.type_vars v in
  v, { env with type_vars = map }

let add_term_var env l =
  let new_var ty = Expr.Id.ty (new_term_name ()) ty in
  let v', map = add_var Expr.Debug.id_ty new_var M.add env.term_vars l in
  v', { env with term_vars = map }

let find_var env name =
  try `Ty (M.find name env.type_vars)
  with Not_found ->
    begin
      try
        `Term (M.find name env.term_vars)
      with Not_found ->
        `Not_found
    end

(* Add local bound variables to env *)
let add_let_term env name t = { env with term_lets = M.add name t env.term_lets }
let add_let_prop env name t = { env with prop_lets = M.add name t env.prop_lets }

let find_let env name =
  try `Term (M.find name env.term_lets)
  with Not_found ->
    begin
      try
        `Prop (M.find name env.prop_lets)
      with Not_found ->
        `Not_found
    end

(* Wrappers for expression building *)
(* ************************************************************************ *)

let arity f =
  List.length Expr.(f.id_type.fun_vars) +
  List.length Expr.(f.id_type.fun_args)

let ty_apply ast_term ~status f args =
  try
    Expr.Ty.apply ~status f args
  with Expr.Bad_ty_arity _ ->
    _bad_arity Expr.(f.id_name) (arity f) ast_term

let term_apply ast_term ~status f ty_args t_args =
  try
    Expr.Term.apply ~status f ty_args t_args
  with
  | Expr.Bad_arity _ ->
    _bad_arity Expr.(f.id_name) (arity f) ast_term
  | Expr.Type_mismatch (t, ty, ty') ->
    _type_mismatch t ty ty' ast_term

let make_eq ast_term a b =
  try
    Expr.Formula.eq a b
  with Expr.Type_mismatch (t, ty, ty') ->
    _type_mismatch t ty ty' ast_term

let make_pred ast_term p =
  try
    Expr.Formula.pred p
  with Expr.Type_mismatch (t, ty, ty') ->
    _type_mismatch t ty ty' ast_term

let infer env s args =
  match env.expect with
  | Nothing -> `Nothing
  | Type ->
    let n = List.length args in
    `Ty (Expr.Id.ty_fun s n)
  | Typed ty ->
    let n = List.length args in
    `Term (Expr.Id.term_fun s [] (CCList.replicate n Expr.Ty.base) ty)

(* Expression parsing *)
(* ************************************************************************ *)

(*
let parse_ttype_var = function
  | { Ast.term = Ast.Var s }
  | { Ast.term = Ast.Column (
          { Ast.term = Ast.Var s },
          {Ast.term = Ast.Const Ast.Ttype}) } ->
    Expr.Id.ttype s
  | t -> _expected "type variable" t

let rec parse_sig ~status env = function
  | { Ast.term = Ast.Binding (Ast.All, vars, t) } ->
    let typed_vars = List.map parse_ttype_var vars in
    let typed_vars, env' = add_type_vars ~status env typed_vars in
    let params, args, ret = parse_sig ~status env' t in
    (typed_vars @ params, args, ret)
  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Arrow}, ret :: args) } ->
    [], List.map (parse_ty ~infer:true ~status env) args, parse_ty ~infer:true ~status env ret
  | t -> [], [], parse_ty ~infer:true ~status env t

let parse_ty_var ~status env = function
  | { Ast.term = Ast.Var s } ->
    Expr.Id.ty s Expr.Ty.base
  | { Ast.term = Ast.Column ({ Ast.term = Ast.Var s }, ty) } ->
    Expr.Id.ty s (parse_ty ~infer:true ~status env ty)
  | t -> _expected "(typed) variable" t

let parse_let_var eval = function
  | { Ast.term = Ast.Column ({ Ast.term = Ast.Var s}, t) } -> (s, eval t)
  | t -> _expected "'let' construct" t

let rec parse_quant_vars ~status env = function
  | [] -> [], [], env
  | (v :: r) as l ->
    try
      let ttype_var = parse_ttype_var v in
      let ttype_var, env' = add_type_var ~status env ttype_var in
      let l, l', env'' = parse_quant_vars ~status env' r in
      ttype_var :: l, l', env''
    with Typing_error _ ->
      let l' = List.map (parse_ty_var ~status env) l in
      let l'', env' = add_term_vars ~status env l' in
      [], l'', env'
*)

let rec parse_expr (env : env) = function

  (* Basic formulas *)
  | { Ast.term = Ast.App ({ Ast.term = Ast.Const Ast.True }, []) }
  | { Ast.term = Ast.Const Ast.True } ->
    Formula Expr.Formula.f_true

  | { Ast.term = Ast.App ({ Ast.term = Ast.Const Ast.False }, []) }
  | { Ast.term = Ast.Const Ast.False } ->
    Formula Expr.Formula.f_false

  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.And}, l) } ->
    Formula (Expr.Formula.f_and (List.map (parse_formula env) l))

  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Or}, l) } ->
    Formula (Expr.Formula.f_or (List.map (parse_formula env) l))

  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Xor}, l) } as t ->
    begin match l with
      | [p; q] ->
        Formula (
          Expr.Formula.neg (
            Expr.Formula.equiv
              (parse_formula env p)
              (parse_formula env q)
          ))
      | _ -> _bad_arity "xor" 2 t
    end

  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Imply}, l) } as t ->
    begin match l with
      | [p; q] ->
        Formula (
          Expr.Formula.imply
            (parse_formula env p)
            (parse_formula env q)
        )
      | _ -> _bad_arity "=>" 2 t
    end

  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Equiv}, l) } as t ->
    begin match l with
      | [p; q] ->
        Formula (
          Expr.Formula.equiv
            (parse_formula env p)
            (parse_formula env q)
        )
      | _ -> _bad_arity "<=>" 2 t
    end

  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Not}, l) } as t ->
    begin match l with
      | [p] ->
        Formula (Expr.Formula.neg (parse_formula env p))
      | _ -> _bad_arity "not" 1 t
    end

  (* Binders *)
  | { Ast.term = Ast.Binding (Ast.All, vars, f) } ->
    let ttype_vars, ty_vars, env' = parse_quant_vars env vars in
    Formula (
      Expr.Formula.allty ttype_vars
        (Expr.Formula.all ty_vars (parse_formula env' f))
    )

  | { Ast.term = Ast.Binding (Ast.Ex, vars, f) } ->
    let ttype_vars, ty_vars, env' = parse_quant_vars env vars in
    Formula (
      Expr.Formula.exty ttype_vars
        (Expr.Formula.ex ty_vars (parse_formula env' f))
    )

  | { Ast.term = Ast.Binding (Ast.Let, vars, f) } ->
    parse_let env f vars

  (* (Dis)Equality *)
  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Eq}, l) } as t ->
    begin match l with
      | [a; b] ->
        Formula (
          make_eq t
            (parse_term env a)
            (parse_term env b)
        )
      | _ -> _bad_arity "=" 2 t
    end

  | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Distinct}, args) } as t ->
    let l' = List.map (parse_term { env with expect = Typed Expr.Ty.base}) args in
    let l'' = CCList.diagonal l' in
    Formula (
      Expr.Formula.f_and
        (List.map (fun (a, b) -> Expr.Formula.neg (make_eq t a b)) l'')
    )

  (* General case: application *)
  | ({ Ast.term = Ast.Const Ast.String s } as t) ->
    parse_app env t s []
  | { Ast.term = Ast.App ({ Ast.term = Ast.Const Ast.String s }, l) } as t ->
    parse_app env t s l

  | t -> _err t

and parse_var env = function
  | { Ast.term = Ast.Column ({ Ast.term = Ast.Const Ast.String s }, e) } ->
    begin match parse_expr env e with
      | Ttype -> `Ty (Expr.Id.ttype s)
      | Ty ty -> `Term (Expr.Id.ty s ty)
      | _ -> _expected "type (or Ttype)" e
    end
  | { Ast.term = Ast.Const Ast.String s } ->
    begin match env.expect with
      | Nothing -> assert false
      | Type -> `Ty (Expr.Id.ttype s)
      | Typed ty -> `Term (Expr.Id.ty s ty)
    end
  | t -> _expected "(typed) variable" t

and parse_quant_vars env l =
  let ttype_vars, typed_vars, env' = List.fold_left (
      fun (l1, l2, acc) v ->
        match parse_var acc v with
        | `Ty v' ->
          let v'', acc' = add_type_var env v' in
          (v'' :: l1, l2, acc')
        | `Term v' ->
          let v'', acc' = add_term_var env v' in
          (l1, v'' :: l2, acc')
    ) ([], [], { env with expect = Typed Expr.Ty.base }) l in
  List.rev ttype_vars, List.rev typed_vars, env'

and parse_let env f = function
  | [] -> parse_expr env f
  | x :: r ->
    begin match x with
      | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Eq}, [
          { Ast.term = Ast.Const Ast.String s }; e]) } ->
        let t = parse_term env e in
        let env' = add_let_term env s t in
        parse_let env' f r
      | { Ast.term = Ast.App ({Ast.term = Ast.Const Ast.Equiv}, [
          { Ast.term = Ast.Const Ast.String s }; e]) } ->
        let t = parse_formula env e in
        let env' = add_let_prop env s t in
        parse_let env' f r
      | { Ast.term = Ast.Column ({ Ast.term = Ast.Const Ast.String s }, e) } ->
        begin match parse_expr env e with
          | Term t ->
            let env' = add_let_term env s t in
            parse_let env' f r
          | Formula t ->
            let env' = add_let_prop env s t in
            parse_let env' f r
          | _ -> _expected "term of formula" e
        end
      | t -> _expected "let-binding" t
    end


and parse_app env ast s args =
  match find_let env s with
  | `Term t ->
    if args = [] then Term t
    else _fo_term s ast
  | `Prop p ->
    if args = [] then Formula p
    else _fo_term s ast
  | `Not_found ->
    begin match find_var env s with
      | `Ty f ->
        if args = [] then Ty (Expr.Ty.of_id f)
        else _fo_term s ast
      | `Term f ->
        if args = [] then Term (Expr.Term.of_id f)
        else _fo_term s ast
      | `Not_found ->
        begin match find_global s with
          | `Ty f -> parse_app_ty env ast f args
          | `Term f -> parse_app_term env ast f args
          | `Not_found ->
            begin match env.builtins s args with
              | Some `Ty ty -> Ty ty
              | Some `Term t -> Term t
              | Some `Formula p -> Formula p
              | None ->
                begin match infer env s args with
                  | `Ty f -> parse_app_ty env ast f args
                  | `Term f -> parse_app_term env ast f args
                  | `Nothing -> _scope_err s ast
                end
            end
        end
    end

and parse_app_ty env ast f args =
  let l = List.map (parse_ty env) args in
  Ty (ty_apply ast ~status:env.status f l)

and parse_app_term env ast f args =
  let n = List.length Expr.(f.id_type.fun_vars) in
  let ty_l, t_l = CCList.take_drop n args in
  let ty_args = List.map (parse_ty env) ty_l in
  let t_args = List.map (parse_term env) t_l in
  Term (term_apply ast ~status:env.status f ty_args t_args)

and parse_ty env ast =
  match parse_expr env ast with
  | Ty ty -> ty
  | _ -> _expected "type" ast

and parse_term env ast =
  match parse_expr env ast with
  | Term t -> t
  | _ -> _expected "term" ast

and parse_formula env ast =
  match parse_expr env ast with
  | Formula p -> p
  | _ -> _expected "formula" ast

(* High-level parsing functions *)
(* ************************************************************************ *)

let new_type_def (sym, n) =
  Util.enter_prof section;
  begin match sym with
    | Ast.String s -> add_type s (Expr.Id.ty_fun s n)
    | _ -> log 0 "Illicit type declaration for symbol : %a" Ast.debug_symbol sym
  end;
  Util.exit_prof section

let new_const_def builtins (sym, t) =
  Util.enter_prof section;
  begin match sym with
    | Ast.String s ->
      let params, args, ret = parse_sig ~status:Expr.Status.hypothesis (empty_env builtins) t in
      add_cst s (Expr.Id.term_fun s params args ret)
    | _ ->
      log 0 "Illicit type declaration for symbol : %a" Ast.debug_symbol sym
  end;
  Util.exit_prof section

let parse ~goal builtins t =
  Util.enter_prof section;
  let status = if goal then Expr.Status.goal else Expr.Status.hypothesis in
  let f = parse_formula ~status (empty_env builtins) t in
  log 1 "New expr : %a" Expr.Debug.formula f;
  Util.exit_prof section;
  f


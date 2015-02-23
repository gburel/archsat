
(* Unification module *)

(* WARNING : In our case,
 * what are usually called 'variables' in litterature are
 * actually the metavariables in the terms *)

exception Not_unifiable_ty of Expr.ty * Expr.ty
exception Not_unifiable_term of Expr.term * Expr.term

let log_section = Util.Section.make "unif"
let log i fmt = Util.debug ~section:log_section i fmt

(* Metavariable protection *)
(* ************************************************************************ *)

let rec protect_term = function
    | { Expr.term = Expr.Meta m } -> Expr.term_meta (Expr.protect m)
    | { Expr.term = Expr.App (f, ty_l, t_l) } ->
      Expr.term_app f ty_l (List.map protect_term t_l)
    | t -> t

(* Unifiers *)
(* ************************************************************************ *)

(* Definition *)
type t = {
  ty_map : (Expr.ttype Expr.meta, Expr.ty) Expr.Subst.t;
  t_map : (Expr.ty Expr.meta, Expr.term) Expr.Subst.t;
}

let debug_unif b s =
  Expr.Subst.iter (fun m ty -> Printf.bprintf b "%a -> %a; " Expr.debug_meta m Expr.debug_ty ty) s.ty_map;
  Expr.Subst.iter (fun m t -> Printf.bprintf b "%a -> %a; " Expr.debug_meta m Expr.debug_term t) s.t_map

let empty = { ty_map = Expr.Subst.empty; t_map = Expr.Subst.empty; }

let mem_ty subst m = Expr.Subst.Meta.mem m subst.ty_map
let mem_term subst m = Expr.Subst.Meta.mem m subst.t_map

let get_ty subst m = Expr.Subst.Meta.get m subst.ty_map
let get_term subst m = Expr.Subst.Meta.get m subst.t_map

let bind_ty subst m t = { subst with ty_map = Expr.Subst.Meta.bind m t subst.ty_map }
let bind_term subst m t = { subst with t_map = Expr.Subst.Meta.bind m t subst.t_map }

let hash s =
  Hashtbl.hash (Expr.Subst.hash Expr.Ty.hash s.ty_map, Expr.Subst.hash Expr.Term.hash s.t_map)

let compare s u =
  match Expr.Subst.compare Expr.Ty.compare s.ty_map u.ty_map with
  | 0 -> Expr.Subst.compare Expr.Term.compare s.t_map u.t_map
  | x -> x

let equal s u =
    Expr.Subst.equal Expr.Ty.equal s.ty_map u.ty_map &&
    Expr.Subst.equal Expr.Term.equal s.t_map u.t_map

let merge s s' = {
    ty_map = Expr.Subst.fold Expr.Subst.Meta.bind s.ty_map s'.ty_map;
    t_map = Expr.Subst.fold Expr.Subst.Meta.bind s.t_map s'.t_map;
}

(* Instanciation helpers *)
let free_args = function
  | { Expr.formula = Expr.All (_, args, _) }
  | { Expr.formula = Expr.Ex (_, args, _) }
  | { Expr.formula = Expr.Not { Expr.formula = Expr.All (_, args, _) } }
  | { Expr.formula = Expr.Not { Expr.formula = Expr.Ex (_, args, _) } }
  | { Expr.formula = Expr.AllTy (_, args, _) }
  | { Expr.formula = Expr.ExTy (_, args, _) }
  | { Expr.formula = Expr.Not { Expr.formula = Expr.AllTy (_, args, _) } }
  | { Expr.formula = Expr.Not { Expr.formula = Expr.ExTy (_, args, _) } } -> args
  | _ -> assert false

let free_args_ty m = free_args (Expr.get_meta_ty_def Expr.(m.meta_index))
let free_args_term m = free_args (Expr.get_meta_def Expr.(m.meta_index))

let merge_free_args (ty1, t1) (ty2, t2) =
    List.merge Expr.Ty.compare ty1 ty2,
    List.merge Expr.Term.compare t1 t2

let belong_ty m s =
    let aux e m' _ = Expr.(m.meta_index = m'.meta_index) ||
                     List.exists (Expr.Ty.equal e) (fst (free_args_ty m')) in
    Expr.Subst.exists (aux (Expr.type_meta m)) s.ty_map

let belong_term m s =
    let aux e m' _ = Expr.(m.meta_index = m'.meta_index) ||
                     List.exists (Expr.Term.equal e) (snd (free_args_term m')) in
    Expr.Subst.exists (aux (Expr.term_meta m)) s.t_map

let split s =
  let rec aux bind belongs acc m t = function
      | [] -> bind empty m t :: acc
      | s :: r ->
        if belongs m s then
          (bind s m t) :: (List.rev_append acc r)
        else
          aux bind belongs (s :: acc) m t r
  in
  let l = Expr.Subst.fold (aux bind_term belong_term []) s.t_map
      (Expr.Subst.fold (aux bind_ty belong_ty []) s.ty_map [])
  in
  log 5 "Starting from : %a" debug_unif s;
  List.iter (fun u -> log 5 " |- %a" debug_unif u) l;
  l

let complete s =
    let aux_ty subst = function
        | { Expr.ty = Expr.TyMeta m } as t -> if mem_ty subst m then subst else bind_ty subst m t
        | _ -> subst
    in
    let aux_term subst = function
        | { Expr.term = Expr.Meta m } as t -> if mem_term subst m then subst else bind_term subst m t
        | _ -> subst
    in
    let l, l' = Expr.Subst.fold (fun m _ acc -> merge_free_args acc (free_args_term m)) s.t_map
        (Expr.Subst.fold (fun m _ acc -> merge_free_args acc (free_args_ty m)) s.ty_map ([], []))
    in
    let u = List.fold_left aux_term (List.fold_left aux_ty s l) l' in
    log 5 "Starting from : %a" debug_unif s;
    log 5 "Got : %a" debug_unif u;
    u

(* Robinson unification *)
(* ************************************************************************ *)

let follow_ty subst = function
  | { Expr.ty = Expr.TyMeta m } -> get_ty subst m
  | _ -> raise Not_found

let follow_term subst = function
  | { Expr.term = Expr.Meta m } -> get_term subst m
  | _ -> raise Not_found

let rec occurs_check_ty subst v = function
    | { Expr.ty = Expr.TyMeta m } as v' ->
      begin try occurs_check_ty subst v (get_ty subst m)
      with Not_found -> Expr.Ty.equal v v' end
    | { Expr.ty = Expr.TyApp (f, l) } -> List.exists (occurs_check_ty subst v) l
    | _ -> false

let rec occurs_check_term subst v = function
    | { Expr.term = Expr.Meta m } as v' ->
      begin try occurs_check_term subst v (get_term subst m)
      with Not_found -> Expr.Term.equal v v' end
    | { Expr.term= Expr.App (f, _, l) } -> List.exists (occurs_check_term subst v) l
    | _ -> false

let rec meta_unify_ty subst s t =
    try meta_unify_ty subst (follow_ty subst s) t with Not_found ->
    try meta_unify_ty subst s (follow_ty subst t) with Not_found ->
      begin match s, t with
        | _ when Expr.Ty.equal s t -> subst
        | _, { Expr.ty = Expr.TyVar _ } | { Expr.ty = Expr.TyVar _}, _ -> assert false
        | { Expr.ty = Expr.TyMeta ({ Expr.meta_var = v1 } as m)},
          { Expr.ty = Expr.TyMeta { Expr.meta_var = v2 } } ->
          if Expr.Var.equal v1 v2 then
              bind_ty subst m t
          else
              raise (Not_unifiable_ty (s, t))
        | { Expr.ty = Expr.TyApp (f, f_args) },
          { Expr.ty = Expr.TyApp (g, g_args) } ->
          if Expr.Var.equal f g then
            List.fold_left2 meta_unify_ty subst f_args g_args
          else
            raise (Not_unifiable_ty (s, t))
        | _ -> raise (Not_unifiable_ty (s, t))
      end

let rec meta_unify_term subst s t =
    log 90 "trying %a <-> %a" Expr.debug_term s Expr.debug_term t;
    try meta_unify_term subst (follow_term subst s) t with Not_found ->
    try meta_unify_term subst s (follow_term subst t) with Not_found ->
      begin match s, t with
        | _ when Expr.Term.equal s t -> subst
        | _, { Expr.term = Expr.Var _ } | { Expr.term = Expr.Var _}, _ -> assert false
        | { Expr.term = Expr.Meta ({ Expr.meta_var = v1 } as m) },
          { Expr.term = Expr.Meta { Expr.meta_var = v2 } } ->
          if Expr.Var.equal v1 v2 then
            bind_term subst m t
          else
              raise (Not_unifiable_term (s, t))
        | { Expr.term = Expr.App (f, f_ty_args, f_t_args) },
          { Expr.term = Expr.App (g, g_ty_args, g_t_args) } ->
          if Expr.Var.equal f g then
            List.fold_left2 meta_unify_term
              (List.fold_left2 meta_unify_ty subst f_ty_args g_ty_args)
              f_t_args g_t_args
          else
            raise (Not_unifiable_term (s, t))
        | _ -> raise (Not_unifiable_term (s, t))
      end

let rec robinson_ty subst s t =
    try robinson_ty subst (follow_ty subst s) t with Not_found ->
    try robinson_ty subst s (follow_ty subst t) with Not_found ->
      begin match s, t with
        | _ when Expr.Ty.equal s t -> subst
        | _, { Expr.ty = Expr.TyVar _ } | { Expr.ty = Expr.TyVar _}, _ -> assert false
        | ({ Expr.ty = Expr.TyMeta ({Expr.can_unify= true} as v) } as m), u
        | u, ({ Expr.ty = Expr.TyMeta ({Expr.can_unify = true} as v) } as m) ->
          if occurs_check_ty subst m u then
            raise (Not_unifiable_ty (m, u))
          else
            bind_ty subst v u
        | { Expr.ty = Expr.TyApp (f, f_args) },
          { Expr.ty = Expr.TyApp (g, g_args) } ->
          if Expr.Var.equal f g then
            List.fold_left2 robinson_ty subst f_args g_args
          else
            raise (Not_unifiable_ty (s, t))
        | _ -> raise (Not_unifiable_ty (s, t))
      end

let rec robinson_term subst s t =
    try robinson_term subst (follow_term subst s) t with Not_found ->
    try robinson_term subst s (follow_term subst t) with Not_found ->
      begin match s, t with
        | _ when Expr.Term.equal s t -> subst
        | _, { Expr.term = Expr.Var _ } | { Expr.term = Expr.Var _}, _ -> assert false
        | ({ Expr.term = Expr.Meta ({Expr.can_unify= true} as v) } as m), u
        | u, ({ Expr.term = Expr.Meta ({Expr.can_unify = true} as v) } as m) ->
          if occurs_check_term subst m u then
            raise (Not_unifiable_term (m, u))
          else
            bind_term subst v u
        | { Expr.term = Expr.App (f, f_ty_args, f_t_args) },
          { Expr.term = Expr.App (g, g_ty_args, g_t_args) } ->
          if Expr.Var.equal f g then
            List.fold_left2 robinson_term
              (List.fold_left2 robinson_ty subst f_ty_args g_ty_args)
              f_t_args g_t_args
          else
            raise (Not_unifiable_term (s, t))
        | _ -> raise (Not_unifiable_term (s, t))
      end

let unify_ty s t = robinson_ty empty s t
let unify_term s t = robinson_term empty s t

let unify_meta_ty s t = meta_unify_ty empty s t
let unify_meta_term s t = meta_unify_term empty s t

let equal_up_to_metas u u' =
    try
        let _ = Expr.Subst.fold (fun m t acc -> meta_unify_term acc (get_term u' m) t) u.t_map
               (Expr.Subst.fold (fun m ty acc -> meta_unify_ty acc (get_ty u' m) ty) u.ty_map empty)
        in
        true
    with Not_found | Not_unifiable_ty _ | Not_unifiable_term _ ->
        false

(* Robinson unification with Caching (modulo meta switching) for term unification *)
(* ************************************************************************ *)

module H = Hashtbl.Make(struct
    type t = Expr.term * Expr.term
    let hash (s, t) = Hashtbl.hash (Expr.Term.hash s, Expr.Term.hash t)
    let equal (s1, t1) (s2, t2) =
        log 50 "testin meta-eq of %a,%a and %a,%a" Expr.debug_term s1 Expr.debug_term t1 Expr.debug_term s2 Expr.debug_term t2;
        try
            let tmp = meta_unify_term empty s1 s2 in
            log 50 "found first unif";
            Expr.Subst.iter (fun m t -> log 60 " |- %a -> %a" Expr.debug_meta m Expr.debug_term t) tmp.t_map;
            let _ = meta_unify_term tmp t1 t2 in
            log 60 "meta-unifiable !";
            true
        with Not_unifiable_ty _ | Not_unifiable_term _ ->
            false
end)

let cache = H.create 4096

let cached_unify s t =
  let key = (s, t) in
  try
      H.find cache key
  with Not_found ->
      log 15 "starting unification";
      let res = unify_term s t in
      H.add cache key res;
      res



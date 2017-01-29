
let section = Dispatcher.solver_section

(* Msat instanciation *)
(* ************************************************************************ *)

module S = Msat.Internal.Make
    (Dispatcher.SolverTypes)
    (Dispatcher.SolverTheory)
    ()

(* Proof replay helpers *)
(* ************************************************************************ *)

type model = (Expr.term * Expr.term) list
(** The type of models for first order problems *)

type view = (Expr.formula -> unit) -> unit
(** A view of the trail when SAT is reached. *)

type proof = S.Proof.proof
(** A proof of UNSAT. *)

type res =
  | Sat of model
  | Unsat of proof
  | Unknown

(* Proof replay helpers *)
(* ************************************************************************ *)

type unsat_ret =
  | Unsat_ok

type sat_ret =
  | Sat_ok
  | Restart
  | Assume of Expr.formula list

type _ Dispatcher.msg +=
  | Found_sat : view -> sat_ret Dispatcher.msg
  | Found_unsat : proof -> unsat_ret Dispatcher.msg
  | Found_unknown : unit -> unit Dispatcher.msg

(* Solving module *)
(* ************************************************************************ *)

let if_sat_iter s f =
  let open Msat.Plugin_intf in
  for i = s.start to s.start + s.length - 1 do
    match s.get i with
    | Lit g -> f g
    | _ -> ()
  done

let if_sat acc = function
  | None | Some Sat_ok -> acc
  | Some Restart -> Restart
  | Some Assume l ->
    begin match acc with
      | Restart -> Restart
      | Sat_ok -> Assume l
      | Assume l' -> Assume (l @ l')
    end

let rec solve_aux ?(assumptions = []) () =
  match begin
    Util.debug ~section 5 "Preparing solver";
    let () = S.pop () in
    let () = S.push () in
    let () = S.local assumptions in
    Util.debug ~section 5 "Solving problem";
    let () = S.solve () in
    Util.debug ~section 1 "Found SAT";
    let view = if_sat_iter (S.full_slice ()) in
    Dispatcher.handle if_sat Sat_ok (Found_sat view)
  end with
  | Sat_ok ->
    Sat (Dispatcher.model ())
  | Restart ->
    Util.debug ~section 1 "Restarting...";
    solve_aux ()
  | Assume assumptions ->
    Util.debug ~section 1 "New assumptions: %a"
      (CCPrint.list ~start:"" ~stop:"" ~sep:" && " Expr.Debug.formula) assumptions;
    solve_aux ~assumptions ()
  | exception S.Unsat ->
    Util.debug ~section 1 "Found UNSAT";
    let proof =
      match S.unsat_conflict () with
      | None -> assert false
      | Some c -> S.Proof.prove_unsat c
    in
    Unsat proof

let solve () =
  Util.enter_prof section;
  let res = solve_aux () in
  Util.exit_prof section;
  res

let assume l =
  Util.enter_prof section;
  let l = List.map (List.map Dispatcher.pre_process) l in
  List.iter (fun cl -> Util.debug ~section 1 "Assuming : %a"
                (CCPrint.list ~sep:"; " Expr.Debug.formula) cl) l;
  let () = S.assume l in
  Util.exit_prof section


(* Model manipulation *)
(* ************************************************************************ *)

module Model = struct

  type t = model

  let rec print_aux fmt = function
    | [] -> ()
    | (u, v) :: r ->
      Format.fprintf fmt "%a -> %a@\n"
        Expr.Term.print u Expr.Term.print v;
      print_aux fmt r

  let print fmt l =
    Format.fprintf fmt "@[<hov 2>Model:@\n%a@]" print_aux l


end



(** Proof in the Coq format

    This module defines helprs for printing coq proof scripts
    corresponding to unsatisfiability proofs.
*)

(** {2 Dispatcher messages} *)

type prelude = private
  | Require of string

type raw_proof = {
  prelude : prelude list;
  proof : Format.formatter -> unit -> unit;
}

type ordered_proof = {
  prelude : prelude list;
  order : Expr.formula list;
  proof : Format.formatter -> unit -> unit;
}

type impl_proof = {
  prelude : prelude list;
  prefix  : string;
  left    : Expr.formula list;
  right   : Expr.formula list;
  proof   : Format.formatter -> Proof.Ctx.t -> unit;
}

type proof_style =
  | Raw of raw_proof
  | Ordered of ordered_proof
  | Implication of impl_proof

type _ Dispatcher.msg +=
  | Prove : Dispatcher.lemma_info -> proof_style Dispatcher.msg (**)
(** Sent to the extension that produced a proof; asks for it to prove the
    clause/lemma it produced, using a coq script.  *)


(** {2 Main} *)

val declare_ty : Format.formatter -> Expr.ttype Expr.function_descr Expr.id -> unit
val declare_term : Format.formatter -> Expr.ty Expr.function_descr Expr.id -> unit
(** Print the type declarations for constant symbols *)

val print_hyp : Format.formatter -> (Dolmen.Id.t * Expr.formula list) -> unit
(** Print an hypothesis/axiom *)

val print_proof : Format.formatter -> Solver.proof -> unit
(** Print a theorem, proving the named goals previously added using the given proof. *)


(** {2 Prelude} *)

module Prelude : sig

  val classical : prelude

end

(** {2 Proof helpers} *)

val exact : Format.formatter -> ('a, Format.formatter, unit) format -> 'a
(** Helper to use the 'exact' coq tactic. *)

val pose_proof : Proof.Ctx.t -> Expr.formula ->
  Format.formatter -> ('a, Format.formatter, unit) format -> 'a
(** Helper to use the 'pose proof' coq tactic. *)

val fun_binder : Format.formatter -> _ Expr.id list -> unit
(** Helper to print function arguments, effectively prints the
    space-separated list of ids. *)

val app_t : Proof.Ctx.t -> Format.formatter -> Expr.formula * Expr.term list -> unit
(** Helper to print the application of the named formula to a list of arguments. *)

(** {2 Printing expressions} *)

module Print : sig

  val id : Format.formatter -> _ Expr.id -> unit
  val dolmen : Format.formatter -> Dolmen.Id.t -> unit

  val ty : Format.formatter -> Expr.ty -> unit
  val term : Format.formatter -> Expr.term -> unit
  val formula : Format.formatter -> Expr.formula -> unit

  val path : Format.formatter -> int * int -> unit
  val path_to : Format.formatter -> Expr.formula * Expr.f_order -> unit

  val pattern :
    start:(Format.formatter -> unit -> unit) ->
    stop:(Format.formatter -> unit -> unit) ->
    sep:(Format.formatter -> unit -> unit) ->
    (Format.formatter -> 'a -> unit) ->
    Format.formatter -> 'a Expr.order -> unit

  val pattern_or :
    (Format.formatter -> 'a -> unit) ->
    Format.formatter -> 'a Expr.order -> unit
  val pattern_and :
    (Format.formatter -> 'a -> unit) ->
    Format.formatter -> 'a Expr.order -> unit
  val pattern_ex :
    (Format.formatter -> 'a -> unit) ->
    Format.formatter -> 'a Expr.order -> unit
  val pattern_intro_and :
    (Format.formatter -> 'a -> unit) ->
    Format.formatter -> 'a Expr.order -> unit

end


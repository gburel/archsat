
(** Rwrite rules

    This module sdefines types and manipulation functions on rerite rules.
*)

(** {2 Rewrite rule guards} *)

module Guard : sig

  type t =
    | Pred_true of Expr.term
    | Pred_false of Expr.term
    | Eq of Expr.term * Expr.term

  val map : (Expr.term -> Expr.term) -> t -> t
  (** Map a function on the terms in a guard. *)

  val to_list : t -> Expr.term list
  (** Returns the list of all top-level terms appearing in a guard. *)

  val check : t -> bool
  (** Check wether a guard is verified. *)

end

(** {2 Rewrite rules} *)

module Rule : sig

  type 'a witness =
    | Term : Expr.term witness
    | Formula : Expr.formula witness

  type 'a rewrite = {
    trigger : 'a;
    result : 'a;
  }

  type contents = C : 'a witness * 'a rewrite -> contents

  type t = {
    id       : int;
    manual   : bool;
    formula  : Expr.formula;
    guards   : Guard.t list;
    contents : contents;
  }
  (** A rewrite rule *)

  val hash : t -> int
  val equal : t -> t -> bool
  val compare : t -> t -> int
  (** Usual functions *)

  val print :
    ?term:Expr.term CCFormat.printer ->
    ?formula:Expr.formula CCFormat.printer ->
    t CCFormat.printer
  (** A modular printer. *)

  val print_id : t CCFormat.printer
  (** Print only the rule id (shorter). *)

  val mk_term : ?guards:Guard.t list -> bool -> Expr.term -> Expr.term -> t
  val mk_formula : ?guards:Guard.t list -> bool -> Expr.formula -> Expr.formula -> t
  (** [mk ?guards is_manual trigger result] creates a new rewrite rule, with
      the formula field set to the constant [true] formula. *)

  val add_guards : Guard.t list -> t -> t
  (** Add the guards to the rule, in no specified order. *)

  val set_formula : Expr.formula -> t -> t
  (** Set the top-level formula of the rewrite rule. *)

  val is_manual : t -> bool
  (** Returns wether the rule is a manual one. *)

end

(** {2 Term normalization} *)

module Normalize : sig

  val normalize_term :
    Rule.t list -> Rule.t list -> Expr.term -> Expr.term * Rule.t list

  val normalize_atomic :
    Rule.t list -> Rule.t list -> Expr.formula -> Expr.formula * Rule.t list

end

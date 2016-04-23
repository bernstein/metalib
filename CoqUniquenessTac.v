(* This file is distributed under the terms of the MIT License, also
   known as the X11 Licence.  A copy of this license is in the README
   file that accompanied the original distribution of this file.

   Based on code written by:
     Brian Aydemir *)

(** Provides a tactic for proving the uniqueness of objects. *)

Require Import Coq.Lists.List.
Require Import Coq.Logic.Eqdep_dec.

Require Import Coq.omega.Omega.


(* *********************************************************************** *)
(** * Auxiliary definitions *)

(** From a list of types, compute the type of a curried function whose
    arguments are those types. *)

Fixpoint arrow (xs : list Type) (res : Type) : Type :=
  match xs with
    | nil => res
    | cons y ys => y -> arrow ys res
  end.

(** From a list of types, compute the type of a heterogeneous list
    whose elements are of those types.  Heterogeneous lists are
    represented as nested tuples. *)

Fixpoint tuple (xs : list Type) : Type :=
  match xs with
    | nil => unit
    | cons y ys => (y * tuple ys)%type
  end.

(** Apply a curried function to a heterogeneous list of arguments. *)

Definition apply_tuple
  (xs : list Type) (res : Type) (f : arrow xs res) (arg : tuple xs)
  : res.
(* begin show *)
Proof.
  induction xs as [ | ? ? IH ]; simpl.
  exact f.
  exact (IH (f (fst arg)) (snd arg)).
Defined.
(* end show *)

(** Reverse a list onto the given accumulator.  Compared to
    [List.rev], this definition simplifies the implementation of
    heterogeneous list reversal (see below). *)

Fixpoint tr_list_rev (A : Type) (xs : list A) (acc : list A) : list A :=
  match xs with
    | nil => acc
    | cons y ys => tr_list_rev A ys (cons y acc)
  end.

Implicit Arguments tr_list_rev [ A ].

(** Reverse a list. *)

Definition list_rev (A : Type) (xs : list A) : list A :=
  tr_list_rev xs nil.

Implicit Arguments list_rev [ A ].

(** Reverse a heterogeneous list onto the given accumulator. *)

Definition tr_tuple_rev
  (xs : list Type) (ab : tuple xs)
  (acc : list Type) (acc' : tuple acc)
  : tuple (tr_list_rev xs acc).
(* begin show *)
Proof.
  generalize dependent acc.
  induction xs as [ | ? ? IH ]; simpl; intros acc acc'.
  exact acc'.
  exact (IH (snd ab) (a :: acc) (fst ab, acc')).
Defined.
(* end show *)

(** Reverse a heterogenous list. *)

Definition tuple_rev
  (xs : list Type) (ab : tuple xs) : tuple (list_rev xs) :=
  tr_tuple_rev xs ab nil tt.


(* *********************************************************************** *)
(** * Auxiliary facts *)

(** This is the minimum set of facts about decidable equality that the
    [uniqueness] tactic (defined below) requires. *)

Lemma eq_unit_dec : forall (x y : unit),
  {x = y} + {x <> y}.
Proof. decide equality. Qed.

Lemma eq_pair_dec : forall (A B : Type),
  (forall x y : A, {x = y} + {x <> y}) ->
  (forall x y : B, {x = y} + {x <> y}) ->
  (forall x y : A * B, {x = y} + {x <> y}).
Proof. decide equality. Qed.

Hint Resolve eq_unit_dec eq_pair_dec : eq_dec.


(* *********************************************************************** *)
(** * Tactic for proving the uniqueness of objects *)

(** [uniqueness] analyzes goals of the form [C x1 .. xn = q] by
    destructing [q] using the [case] tactic.  It is mainly useful when
    [q] is an object of an indexed inductive type [Q], since it
    generalizes the goal such that [case] will succeed.  The argument
    should be the number of indices to [Q], and the indices should not
    depend on each other.

    Subgoals generated by the tactic will require one of three things:
    showing that the goal state is impossible, proving that equality
    at some type is decidable, and proving that any two objects of
    some type are equal.  The tactic [auto with eq_dec] is used to
    discharge subgoals of the second form.  The tactic [auto] is used
    to discharge subgoals of the third form. *)

Ltac uniqueness icount :=
  (** Expose the conclusion. *)
  intros;

  (** If the right hand side looks like a function application, flip
      the equality around.  This is merely so that the remainder of
      this tactic can assume that the goal is in a certain form. *)
  try (match goal with |- _ = ?f _ => symmetry end);

  (** Record the proof on the left hand side of the equality. *)
  let lhs := match goal with |- ?lhs = _ => constr:(lhs) end in

  (** Record the proof on the right hand side of the equality. *)
  let rhs := match goal with |- _ = ?rhs => constr:(rhs) end in

  (** Record the sort of the predicate. *)
  let sort := match type of rhs with
                | ?pred => match type of pred with ?sort => sort end
              end
  in

  (** Extract out the predicate applied only to its parameters.  We
      use the value of [icount] to determine the number of indices. *)
  let rec get_pred_type i pred :=
    match i with
      | O => pred
      | S ?n => match pred with ?f ?x => get_pred_type n f end
    end
  in
  let pred := get_pred_type icount ltac:(type of rhs) in

  (** Extract out the types of the predicate's indices.  We use the
      value of [icount] to determine the number of indices. *)
  let rec get_ind_types i pred acc :=
    match i with
      | O => acc
      | S ?n => match pred with
                  | ?f ?x => let ind := type of x in
                             get_ind_types n f (@cons Type ind acc)
                end
    end
  in
  let ind_types := get_ind_types icount ltac:(type of rhs) (@nil Type) in

  (** Extract out the predicate's indices.  We use the value of
      [icount] to determine the number of indices. *)
  let rec get_inds i pred acc :=
    match i with
      | O => acc
      | S ?n => match pred with ?f ?x => get_inds n f (x, acc) end
    end
  in
  let inds := get_inds icount ltac:(type of rhs) tt in

  (** For technical reasons that will become clear later in this
      tactic, we record reversed versions of the list of types of the
      predicate's indices and of the list of indices. *)
  let rind_types := constr:(list_rev ind_types) in
  let rinds := constr:(tuple_rev ind_types inds) in

  (** Now the real fun begins.  We need massage the goal so that it
      looks like [P index1 ... indexN rhs].  The trick is to define
      [P] appropriately.  The definition of [core] below is the first
      step in defining [P].  Compared to what we want, it is uncurried
      and the indices are in reverse order. *)
  let core :=
    constr:(fun (ainds : tuple rind_types)
                (rhs   : apply_tuple (list_rev rind_types)
                                     sort
                                     pred
                                     (tuple_rev rind_types ainds))
            =>
            forall eqpf : rinds = ainds,
              @eq (apply_tuple (list_rev rind_types)
                               sort
                               pred
                               (tuple_rev rind_types ainds))
                  (@eq_rect (tuple rind_types)
                            rinds
                            (fun rinds2 =>
                              apply_tuple (list_rev rind_types)
                                          sort
                                          pred
                                          (tuple_rev rind_types rinds2))
                            lhs
                            ainds
                            eqpf)
                 rhs)
  in
  let core := eval simpl in core in

  (** Now, we take [core] and curry it.  When we curry [core], we end
      up "reversing" the order of arguments.  Because they started out
      reversed, what we end up with is function that takes the
      predicate's indices in the correct order when compared to the
      predicate's elimination principle.

      Implementation note (BEA): I don't see how to arrive at this
      curried form with out going through the "reversed list" stage. *)
  let rec curry f :=
    match type of f with
      | forall _ : (unit), _ => constr:(f tt)
      | forall _ : (_ * unit), _ => constr:(fun a => f (a, tt))
      | forall _ : (_ * _), _ =>
        let f' := constr:(fun b a => f (a, b)) in curry f'
    end
  in
  let core := curry core in
  let core := eval simpl in core in

  (** Now we supply to [core] the indices and the proof on the right
      hand side of the equality (the one we want to apply [case] to). *)
  let rec apply_core f args :=
    match args with
      | tt => constr:(f)
      | (?x, ?xs) => apply_core (f x) xs
    end
  in
  let core := apply_core core inds in
  let core := constr:(core rhs) in

  (** In order to make [core] convertible with the goal, we need to
      introduce an equality for the predicate's indices and generalize
      over that equality. *)
  change lhs with (@eq_rect (tuple rind_types)
                            rinds
                            (fun rinds2 =>
                              apply_tuple (list_rev rind_types)
                                          sort
                                          pred
                                          (tuple_rev rind_types rinds2))
                            lhs
                            rinds
                            (refl_equal rinds));
  generalize (refl_equal rinds);

  (** We now have everything we need in order to use the [case] tactic. *)
  change core;
  case rhs;

  (** At this point, all that remains is to simplify everything.
      We begin by making sure all functions have reduced. *)
  unfold list_rev, tuple_rev in *;
  simpl tr_list_rev in *;
  simpl tr_tuple_rev in *;

  (** Next, we simplify the equality that we introduced earlier,
      checking for "obvious" contradictions in the process. *)
  repeat (match goal with
            | |- (_, _) = (_, _) -> _ =>
              let H := fresh in intros H; try discriminate; injection H
            | _ => progress intro
          end);
  subst;

  (** All that is left now is to use [eq_rect_eq_dec] to simplify
      occurrences of [eq_rect].  Since we have an equality between
      constructors, we can use [f_equal] to safely make progress from
      there.  We use [auto] and [auto with eq_dec] to clean up any
      subgoals. *)
  try (rewrite <- eq_rect_eq_dec; [ f_equal; auto | auto with eq_dec ]).

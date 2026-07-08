import Mathlib.Data.Set.Lattice
import Mathlib.Data.Set.Function
import Mathlib.Analysis.SpecialFunctions.Log.Basic
import LLMlean

set_option llmlean.api "codex"
set_option llmlean.numSamples 3
set_option llmlean.verbose true
set_option llmlean.validateSuggestions true
-- set_option llmlean.codexCommand "codex app-server"
-- set_option llmlean.codexReadTimeoutMs 10000
-- set_option llmlean.codexTurnTimeoutMs 180000


section

variable {α β : Type*}
variable (f : α → β)
variable (s t : Set α)
variable (u v : Set β)

open Function
open Set

example : f ⁻¹' (u ∩ v) = f ⁻¹' u ∩ f ⁻¹' v := by
  ext
  rfl

example : f '' (s ∪ t) = f '' s ∪ f '' t := by
  sorry

example : s ⊆ f ⁻¹' (f '' s) := by
  sorry

example : f '' s ⊆ v ↔ s ⊆ f ⁻¹' v := by
  sorry

example (h : Injective f) : f ⁻¹' (f '' s) ⊆ s := by
  sorry

example : f '' (f ⁻¹' u) ⊆ u := by
  sorry

example (h : Surjective f) : u ⊆ f '' (f ⁻¹' u) := by
  sorry

example (h : s ⊆ t) : f '' s ⊆ f '' t := by
  sorry

example (h : u ⊆ v) : f ⁻¹' u ⊆ f ⁻¹' v := by
  sorry

example : f ⁻¹' (u ∪ v) = f ⁻¹' u ∪ f ⁻¹' v := by
  sorry

example : f '' (s ∩ t) ⊆ f '' s ∩ f '' t := by
  sorry

example (h : Injective f) : f '' s ∩ f '' t ⊆ f '' (s ∩ t) := by
  sorry

example : f '' s \ f '' t ⊆ f '' (s \ t) := by
  sorry

example : f ⁻¹' u \ f ⁻¹' v ⊆ f ⁻¹' (u \ v) := by
  sorry

example : f '' s ∩ v = f '' (s ∩ f ⁻¹' v) := by
  sorry

example : f '' (s ∩ f ⁻¹' u) ⊆ f '' s ∩ u := by
  sorry

example : s ∩ f ⁻¹' u ⊆ f ⁻¹' (f '' s ∩ u) := by
  sorry

example : s ∪ f ⁻¹' u ⊆ f ⁻¹' (f '' s ∪ u) := by
  sorry

variable {I : Type*} (A : I → Set α) (B : I → Set β)

example : (f '' ⋃ i, A i) = ⋃ i, f '' A i := by
  sorry

example : (f '' ⋂ i, A i) ⊆ ⋂ i, f '' A i := by
  sorry

example (i : I) (injf : Injective f) : (⋂ i, f '' A i) ⊆ f '' ⋂ i, A i := by
  sorry

example : (f ⁻¹' ⋃ i, B i) = ⋃ i, f ⁻¹' B i := by
  sorry

example : (f ⁻¹' ⋂ i, B i) = ⋂ i, f ⁻¹' B i := by
  sorry

example : InjOn f s ↔ ∀ x₁ ∈ s, ∀ x₂ ∈ s, f x₁ = f x₂ → x₁ = x₂ :=
  Iff.refl _

end

section

open Set Real

example : InjOn log { x | x > 0 } := by
  sorry

example : range exp = { y | y > 0 } := by
  sorry

example : InjOn sqrt { x | x ≥ 0 } := by
  sorry

example : InjOn (fun x ↦ x ^ 2) { x : ℝ | x ≥ 0 } := by
  sorry

example : sqrt '' { x | x ≥ 0 } = { y | y ≥ 0 } := by
  sorry

example : (range fun x ↦ x ^ 2) = { y : ℝ | y ≥ 0 } := by
  sorry

end

section
variable {α β : Type*} [Inhabited α]

#check (default : α)

variable (P : α → Prop) (h : ∃ x, P x)

#check Classical.choose h

example : P (Classical.choose h) :=
  Classical.choose_spec h

noncomputable section

open Classical

def inverse (f : α → β) : β → α := fun y : β ↦
  if h : ∃ x, f x = y then Classical.choose h else default

theorem inverse_spec {f : α → β} (y : β) (h : ∃ x, f x = y) : f (inverse f y) = y := by
  unfold inverse
  rw [dif_pos h]
  exact Classical.choose_spec h
  -- unfold inverse
  -- rw [dif_pos h]
  -- exact Classical.choose_spec h
  -- rw [inverse, dif_pos h]
  -- exact Classical.choose_spec h

variable (f : α → β)

open Function

example : Injective f ↔ LeftInverse (inverse f) f := by
  exact ⟨fun hf x ↦ hf (inverse_spec (f := f) (f x) ⟨x, rfl⟩), fun h x y hxy ↦ by rw [← h x, hxy, h y]⟩

example : Surjective f ↔ RightInverse (inverse f) f :=
  sorry

end

section
variable {α : Type*}
open Function

theorem Cantor : ∀ f : α → Set α, ¬Surjective f := by
  llmqed
  -- exact fun f hf => let S : Set α := {x | x ∉ f x}; let a : α := Classical.choose (hf S); let ha : f a = S := Classical.choose_spec (hf S); let hmem_eq : (a ∈ f a) = (a ∈ S) := congrArg (fun T : Set α => a ∈ T) ha; let hn : a ∉ f a := fun hm => (Eq.mp hmem_eq hm) hm; hn (Eq.mpr hmem_eq hn)
  -- exact fun f hf => by let S : Set α := {x | x ∉ f x}; rcases hf S with ⟨a, ha⟩; have h : a ∈ S ↔ a ∉ S := (by change a ∉ f a ↔ a ∉ S; rw [ha]); exact iff_not_self h
  -- intro f surjf
  -- let S := { i | i ∉ f i }
  -- rcases surjf S with ⟨j, h⟩
  -- have h₁ : j ∉ f j := by
  --   intro h'
  --   have : j ∉ f j := by rwa [h] at h'
  --   contradiction
  -- have h₂ : j ∈ S := by sorry
  -- have h₃ : j ∉ S := by sorry
  -- contradiction

-- COMMENTS: TODO: improve this
end

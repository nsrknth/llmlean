import Lean
import LLMlean.API.ProofGen
import LLMlean.API.TacticGen
import LLMlean.LLMstep

open Lean

#eval LLMlean.splitTacs "Please use the `lean` format."

#eval LLMlean.splitTacs "Some prose before the real block.
[TAC]
intro hrs hst x hx
exact hst (hrs hx)
[/TAC]"

#eval LLMlean.splitTacs "```lean4
exact fun hp _ => hp
```"

#eval LLMlean.splitProofs "I’ll use a proof.
[PROOF]
simpa [Nat.Coprime] using h
[/PROOF]
[PROOF]
exact Nat.coprime_iff_gcd_eq_one.mp h
[/PROOF]"

#eval toJson CheckResult.ProofDone

import Lean
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

#eval toJson CheckResult.ProofDone

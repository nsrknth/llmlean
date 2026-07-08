/- Prompt generation for LLMlean -/
import LLMlean.Config

open LLMlean.Config

namespace LLMlean

def proofStyleInstructions (style : String) : String :=
  match style with
  | "" | "default" => ""
  | "tutorial" | "teaching" => s!"
Proof style guidance:
- Prefer readable tutorial-style Lean proof scripts over black-box automation when a short
  structural proof is available.
- Prefer local hypotheses, local definitions, constructors, and tactics such as intro, intros,
  exact, apply, assumption, constructor, cases, induction, rw, simp, and simpa.
- Avoid using decide, omega, aesop, grind, norm_num, linarith, ring, positivity, or other broad
  automation as the first choice for simple tutorial goals.
- If multiple candidates are requested, make them genuinely distinct and include at least one
  step-by-step proof candidate."
  | "automation" => s!"
Proof style guidance:
- Prefer short robust automation when it closes the goal.
- Good candidates include simp, simpa, aesop, grind, omega, norm_num, linarith, ring, positivity,
  and decide when appropriate.
- If multiple candidates are requested, make them genuinely distinct."
  | style => s!"
Proof style guidance:
- Follow this user-requested proof style: {style}."

def tacticPrefixInstructions (pre : String) : String :=
  if pre == "" then
    "No tactic prefix was provided, so return the complete next tactic."
  else
    s!"The tactic prefix is provided in [PREFIX]...[/PREFIX].
Return only the suffix to append after that exact prefix.
Do not repeat, edit, explain, or wrap the prefix."

/--
See `makePrompts`.
-/
def makePromptsFewShot (_context : String) (state : String) (pre proofStyle : String) :
    List String :=
  let style := proofStyleInstructions proofStyle
  let prefixInstruction := tacticPrefixInstructions pre
  let p1 := s!"Given the Lean 4 tactic state, suggest a next tactic.
{prefixInstruction}
Here are some examples:

Tactic state:
---
α : Type u_1
r : α → α → Prop
inst✝¹ : DecidableEq α
inst✝ : IsIrrefl α r
⊢ CutExpand r ≤ InvImage (Finsupp.Lex (rᶜ ⊓ fun x x_1 => x ≠ x_1) fun x x_1 => x < x_1) ↑toFinsupp
---
Next tactic:
---
rintro s t ⟨u, a, hr, he⟩
---

Tactic state:
---
ι : Type u_1
I✝ J✝ : Box ι
x y : ι → ℝ
I J : WithBot (Box ι)
⊢ ↑I = ↑J ↔ I = J
---
Next tactic:
---
simp only [Subset.antisymm_iff, ← le_antisymm_iff, withBotCoe_subset_iff]
---

Tactic state:
---
m n : ℕ
h : Nat.coprime m n
⊢ Nat.gcd m n = 1
---
Next tactic:
---
rw [← h.gcd_eq_one]
---

Tactic state:
---
{state}
---
[PREFIX]
{pre}
[/PREFIX]
{style}
Next tactic completion:
---
{pre}"
  [p1]

/--
See `makePrompts`.
-/
def makePromptsInstruct (context : String) (state : String) (pre proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let prefixInstruction := tacticPrefixInstructions pre
  let p1 := s!"/- You are proving a theorem in Lean 4.
You are given the following information:
- The file contents up to the current tactic, inside [CTX]...[/CTX]
- The current proof state, inside [STATE]...[/STATE]
- The tactic prefix, if any, inside [PREFIX]...[/PREFIX]

Your task is to generate the next tactic in the proof.
Put the next tactic inside [TAC]...[/TAC].
{prefixInstruction}
{style}
-/
[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
[PREFIX]
{pre}
[/PREFIX]
[TAC]
"
  [p1]

/--
See `makePrompts`.
-/
def makePromptsReasoning (context : String) (state : String) (pre proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let prefixInstruction := tacticPrefixInstructions pre
  let p1 := s!"/- You are proving a theorem in Lean 4.
You are given the following information:
- The file contents up to the current tactic, inside [CTX]...[/CTX]
- The current proof state, inside [STATE]...[/STATE]
- The tactic prefix, if any, inside [PREFIX]...[/PREFIX]

Your task is to generate the next tactic in the proof.
Put the next tactic inside [TAC]...[/TAC].
If you find it helpful, you can precede the tactic with brief thoughts inside [THOUGHTS]...[/THOUGHTS]
{prefixInstruction}
In summary, your output should be of the form:
[THOUGHTS]
...
[/THOUGHTS]
[TAC]
...
[/TAC]
{style}

[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
[PREFIX]
{pre}
[/PREFIX]
[THOUGHTS]
"
  [p1]

/--
See `makePrompts`.
-/
def makePromptsMarkdownReasoning
    (context : String) (state : String) (pre proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"You are proving a theorem in Lean 4.
You are given the following information:

The file contents up to the current tactic are as follows:

```lean4
{context}
```

The current proof state is as follows:
{state}

Your task is to generate the next tactic in the proof.
Generate this by writing a markdown file with the completed line, including the context of the file before it
in a markdown code block.
{style}

If you find it helpful, you can precede the proof with brief thoughts. When you are done, end with </think>.

"
  match pre with
  | "" => [p1]
  | pre => [p1 ++ s!"The tactic you generate should start with {pre}"]

/--
See `makePrompts`.
-/
def makePromptsTacticState (_context : String) (state : String) (_pre: String) : List String :=
  let sep := ":::"
  let p1 := state ++ sep
  [p1]

/--
See `makeQedPrompts`.
TODO implement
-/
def makeQedPromptsFewShot (context : String) (state proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"Given the Lean 4 context and tactic state, complete the proof.
Put only the proof script inside [PROOF]...[/PROOF].
Do not include comments, markdown, or explanatory text inside [PROOF].
{style}

[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
[PROOF]"
  [p1]

/--
See `makeQedPrompts`.
-/
def makeQedPromptsInstruct (context : String) (state proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"/- You are proving a theorem in Lean 4.
You are given the following information:
- The file contents up to the current tactic, inside [CTX]...[/CTX]
- The current proof state, inside [STATE]...[/STATE]

Your task is to generate the proof.
Put the proof inside [PROOF]...[/PROOF]
The proof should be a normal Lean tactic script.
Do not include comments, markdown, or explanatory text inside [PROOF].
{style}
-/
[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
[PROOF]"
  [p1]

/--
See `makeQedPrompts`.
-/
def makeQedPromptsReasoning (context : String) (state proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"/- You are proving a theorem in Lean 4.
You are given the following information:
- The file contents up to the current tactic, inside [CTX]...[/CTX]
- The current proof state, inside [STATE]...[/STATE]

Your task is to generate the rest of the proof.
Put the proof script inside [PROOF]...[/PROOF].
If you find it helpful, you can precede the proof with brief thoughts inside [THOUGHTS]...[/THOUGHTS]
In summary, your output should be of the form:
[THOUGHTS]
...
[/THOUGHTS]
[PROOF]
...
[/PROOF]
The proof should be a normal Lean tactic script. Use one tactic per line when that is clearer.
Do not include comments, markdown, or explanatory text inside [PROOF].
{style}
-/
[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
"
  [p1]

/--
See `makeQedPrompts`.
-/
def makeQedPromptsMarkdownReasoning (context : String) (state proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"You are proving a theorem in Lean 4.

You are given the following information:
The file contents up to the current tactic are as follows:
```lean4
{context}
```
The current proof state is as follows:
{state}
Your task is to generate the proof.
Generate this by writing a markdown file with the completed proof, including the context of the file before it
in a markdown code block.

IMPORTANT: you must end by writing your full proof in the format:
```lean4
<... your proof here...>
```
{style}

If you find it helpful, you can precede the proof with brief thoughts, outside the tactic blocks.
IMPORTANT: Once you have written a complete proof, end with </think>.
"
  [p1]

/--
Makes prompts for single tactic generation,
given a `context` containing the file contents up to the tactic invocation,
and a `state` containing the current proof state,
and a `pre` string containing the prefix of the tactic to be generated.
-/
def makePrompts
    (promptKind : PromptKind) (context : String) (state : String) (pre proofStyle : String) :
    List String :=
  match promptKind with
  | PromptKind.FewShot => makePromptsFewShot context state pre proofStyle
  | PromptKind.Reasoning => makePromptsReasoning context state pre proofStyle
  | PromptKind.Instruction => makePromptsInstruct context state pre proofStyle
  | PromptKind.MarkdownReasoning => makePromptsMarkdownReasoning context state pre proofStyle
  | PromptKind.TacticState => makePromptsTacticState context state pre


/--
Makes prompts for the complete proof generation,
given a `context` containing the file contents up to the tactic invocation,
and a `state` containing the current proof state.
-/
def makeQedPrompts
    (promptKind : PromptKind) (context : String) (state proofStyle : String) : List String :=
  match promptKind with
  | PromptKind.FewShot => makeQedPromptsFewShot context state proofStyle
  | PromptKind.Reasoning => makeQedPromptsReasoning context state proofStyle
  | PromptKind.Instruction => makeQedPromptsInstruct context state proofStyle
  | PromptKind.MarkdownReasoning => makeQedPromptsMarkdownReasoning context state proofStyle
  | PromptKind.TacticState => makePromptsTacticState context state ""

def makeQedRefinementPromptsFewShot (context : String) (state : String)
    (previousAttempt : String) (errorMsg proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"Previous proof attempt failed.
Use the error and previous attempt to produce a corrected proof.
Put only the corrected proof script inside [PROOF]...[/PROOF].
Do not include comments, markdown, or explanatory text inside [PROOF].
{style}

[ERROR]
{errorMsg}
[/ERROR]
[PREVIOUS_PROOF]
{previousAttempt}
[/PREVIOUS_PROOF]
[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
[PROOF]"
  [p1]


def makeQedRefinementPromptsInstruct (context : String) (state : String)
    (previousAttempt : String) (errorMsg proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"/- You are proving a theorem in Lean 4.
Your previous proof attempt failed with the following error:
{errorMsg}

Previous attempt:
[PROOF]
{previousAttempt}
[/PROOF]

Please provide a corrected proof that addresses this error.
Put the proof inside [PROOF]...[/PROOF]
{style}
-/
[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
[PROOF]"
  [p1]

def makeQedRefinementPromptsReasoning (context : String) (state : String)
    (previousAttempt : String) (errorMsg proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"/- You are proving a theorem in Lean 4.
Your previous proof attempt failed with the following error:
{errorMsg}

Previous attempt:
{previousAttempt}

Please analyze what went wrong and provide a corrected proof.
Put your analysis inside [THOUGHTS]...[/THOUGHTS] and the corrected proof inside [PROOF]...[/PROOF].
Do not include any additional text outside these blocks.
Write ONLY the proof inside of [PROOF]...[/PROOF]. For instance, do NOT write ```lean4 ... ```.
{style}
-/
[CTX]
{context}
[/CTX]
[STATE]
{state}
[/STATE]
[THOUGHTS]"
  [p1]

def makeQedRefinementPromptsMarkdownReasoning (context : String) (state : String)
    (previousAttempt : String) (errorMsg proofStyle : String) : List String :=
  let style := proofStyleInstructions proofStyle
  let p1 := s!"You are proving a theorem in Lean 4.

Your previous proof attempt failed with the following error:
**Error:** {errorMsg}

**Previous attempt:**
```lean4
{previousAttempt}
```

The file contents up to the current tactic are:
```lean4
{context}
```

The current proof state is:
{state}

Please analyze what went wrong and provide a corrected proof.
Write your thoughts about the error and then provide the complete corrected proof in a markdown code block.

IMPORTANT: End with your corrected proof in the format:
```lean4
<... your corrected proof here...>
```
{style}"
  [p1]

/--
Make refinement prompts for proof completion with error context
-/
def makeQedRefinementPrompts (promptKind : PromptKind) (context : String) (state : String)
    (previousAttempt : String) (errorMsg proofStyle : String) : List String :=
  match promptKind with
  | PromptKind.FewShot =>
      makeQedRefinementPromptsFewShot context state previousAttempt errorMsg proofStyle
  | PromptKind.Instruction =>
      makeQedRefinementPromptsInstruct context state previousAttempt errorMsg proofStyle
  | PromptKind.Reasoning =>
      makeQedRefinementPromptsReasoning context state previousAttempt errorMsg proofStyle
  | PromptKind.MarkdownReasoning =>
      makeQedRefinementPromptsMarkdownReasoning context state previousAttempt errorMsg proofStyle
  | PromptKind.TacticState => makePromptsTacticState context state ""

end LLMlean

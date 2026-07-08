/- Tactic generation for LLMlean -/
import LLMlean.API.Common
import LLMlean.API.Prompts
import LLMlean.API.Codex.Completion

open Lean LLMlean.Config

namespace LLMlean

/--
Parses a tactic out of a response from the LLM.
The tactic is expected to be enclosed in `[TAC]...[/TAC]` tags.
-/
def splitTac (text : String) : String :=
  let text := ((text.splitOn "[TAC]").tailD [text]).headD text
  match (text.splitOn "[/TAC]").head? with
  | some s => s.trim
  | none => text.trim

def firstNonemptyLine (text : String) : String :=
  ((text.splitOn "\n").map (fun line => line.trim)).filter (fun line => line.length > 0)
    |>.headD ""

def startsWithAny (line : String) (prefixes : List String) : Bool :=
  prefixes.any fun pfx => line.startsWith pfx

def containsSubstring (text : String) (needle : String) : Bool :=
  (text.splitOn needle).length > 1

def isLikelyLeanTactic (candidate : String) : Bool :=
  let text := candidate.trim
  let first := firstNonemptyLine text
  text.length > 0
    && !(containsSubstring text "```")
    && !(containsSubstring text "[TAC]")
    && !(containsSubstring text "[/TAC]")
    && startsWithAny first [
      "all_goals", "apply", "assumption", "aesop", "by_cases", "by_contra", "calc",
      "cases", "change", "constructor", "contradiction", "dsimp", "exact", "ext",
      "first", "funext", "have", "intro", "left", "let", "linarith", "norm_num",
      "omega", "rcases", "refine", "rename_i", "rfl", "right", "ring", "rintro",
      "rw", "simp", "simpa", "subst", "tauto", "unfold", "use"
    ]

def fallbackTacticCandidates (text : String) : Array String := Id.run do
  let mut results : Array String := #[]
  for block in getMarkdownLeanCodeBlocks text do
    let block := block.trim
    if isLikelyLeanTactic block then
      results := results.push block
  if !results.isEmpty then
    return results
  let tactic := splitTac text
  if isLikelyLeanTactic tactic then
    return #[tactic.trim]
  else
    return #[]

def splitTacs (text : String) : Array String := Id.run do
  let parts := (text.splitOn "[TAC]").tailD []
  let mut results : Array String := #[]
  for part in parts do
    match (part.splitOn "[/TAC]").head? with
    | some tactic =>
        let tactic := tactic.trim
        if tactic.length > 0 then
          results := results.push tactic
    | none => pure ()
  if results.isEmpty then
    return fallbackTacticCandidates text
  else
    return results

/-!
## Open AI
-/
def parseTacticResponseOpenAI (res: OpenAIResponse) (pfx : String) : Array String :=
  (res.choices.map fun x => pfx ++ (splitTac x.message.content)).toArray

def tacticGenerationOpenAI (pfx : String) (prompts : List String)
(api : API) (options : ChatGenerationOptions) : IO $ Array (String × Float) := do
  let mut results : Std.HashSet String := Std.HashSet.emptyWithCapacity
  for prompt in prompts do
    let req : OpenAIGenerationRequest := {
      model := api.model,
      messages := [
        {
          role := "user",
          content := prompt
        }
      ],
      n := options.numSamples,
      temperature := options.temperature,
      max_tokens := options.maxTokens,
      stop := options.stopSequences
    }
    let res : OpenAIResponse ← post req api.baseUrl api.key
    for result in (parseTacticResponseOpenAI res pfx) do
      results := results.insert result

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults


/-!
## Anthropic
-/
def parseTacticResponseAnthropic (res: AnthropicResponse) (pfx : String) : Array String :=
  (res.content.map fun x => pfx ++ (splitTac x.text)).toArray

def tacticGenerationAnthropic (pfx : String) (prompts : List String)
(api : API) (options : ChatGenerationOptions) : IO $ Array (String × Float) := do
  let mut results : Std.HashSet String := Std.HashSet.emptyWithCapacity
  for prompt in prompts do
    for i in List.range options.numSamples do
      let temperature := if i == 1 then 0.0 else options.temperature
      let req : AnthropicGenerationRequest := {
        model := api.model,
        messages := [
          {
            role := "user",
            content := prompt
          }
        ],
        temperature := temperature,
        max_tokens := options.maxTokens,
        stop_sequences := options.stopSequences
      }
      let res : AnthropicResponse ← post req api.baseUrl api.key
      for result in (parseTacticResponseAnthropic res pfx) do
        results := results.insert result

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Codex app-server
-/

def codexTacticModel? (api : API) : Option String :=
  if api.model.trim == "" then none else some api.model

def codexMultiTacticPrompt (prompt : String) (numSamples : Nat) : String :=
  if numSamples <= 1 then
    prompt
  else
    prompt ++ s!"

For this Codex app-server request, return up to {numSamples} distinct candidate next tactics.
Put each candidate in its own [TAC]...[/TAC] block.
Do not include explanations or comments inside [TAC] blocks."

def tacticGenerationCodex (pfx : String) (prompts : List String)
(api : API) (options : ChatGenerationOptions) : CoreM $ Array (String × Float) := do
  let some prompt := prompts.head?
    | return #[]
  Config.verbosePrint s!"Codex llmstep requested up to {options.numSamples} tactic(s)"
  let prompt := codexMultiTacticPrompt prompt options.numSamples
  Config.verbosePrint s!"Codex prompt length: {prompt.length} characters"
  let response ← LLMlean.Codex.Completion.runConfiguredPrompt prompt (codexTacticModel? api)
  Config.verbosePrint s!"Codex raw response:\n{response}"
  let parsedTactics := splitTacs response
  Config.verbosePrint s!"Codex parsed {parsedTactics.size} tactic block(s)"
  for tactic in parsedTactics do
    Config.verbosePrint s!"Parsed tactic:\n{tactic}"
  let mut results : Std.HashSet String := Std.HashSet.emptyWithCapacity
  for tactic in parsedTactics do
    let tactic := pfx ++ tactic
    if filterGeneration tactic then
      results := results.insert tactic
  Config.verbosePrint s!"Codex kept {results.size} tactic(s) after filtering"
  return results.toArray.map fun tactic => (tactic, 1.0)

/-!
## Ollama
-/
def parseResponseOllama (res: OllamaResponse) : String :=
  splitTac res.response

def tacticGenerationOllama (pfx : String) (prompts : List String)
(api : API) (options : ChatGenerationOptions) : IO $ Array (String × Float) := do
  let mut results : Std.HashSet String := Std.HashSet.emptyWithCapacity
  for prompt in prompts do
    for i in List.range options.numSamples do
      let temperature := if i == 1 then 0.0 else options.temperature
      let req : OllamaGenerationRequest := {
        model := api.model,
        prompt := prompt,
        stream := false,
        options := {
          temperature := temperature,
          num_predict := options.maxTokens,
          stop := options.stopSequences
        }
      }
      let res : OllamaResponse ← post req api.baseUrl api.key
      results := results.insert (pfx ++ (parseResponseOllama res))

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults


/-!
## Ollama with markdown output (e.g., Kimina-Prover)
-/

/--
Given a code block and a context, returns the first line of the code block after the context is written out.
-/
def getTacticFromBlockContext (context : String) (block : String) : String := Id.run do
  -- Get the trimmed last nonempty nonwhitespace line of the context
  let last_context := (((context.splitOn "\n").filter (fun x => x.trim.length > 0)).getLast?.getD "").trim

  -- Trim every line of the block
  let block := "\n".intercalate ((block.splitOn "\n").map (fun x => x.trim))

  let post_context := (block.splitOn last_context)[1]?.getD ""
  if post_context.length > 0 then
    -- get the first nonempty nonwhitespace line of the post_context
    let tactic := ((post_context.splitOn "\n").filter (fun x => x.trim.length > 0)).getLast?.getD ""
    return tactic.trim
  else
    return s!"Did not find context: \n\n{context}\n\n in \n\n{block}\n\n"

def parseTacticResponseOllamaMarkdown (_context : String) (res: OllamaResponse) : List String := Id.run do
  let blocks := getMarkdownLeanCodeBlocks res.response
  let mut results : List String := []
  for block in blocks do
    for line in (block.splitOn "\n") do
      if line.trim.length > 0 then
        results := results ++ [line.trim]
  return results

def tacticGenerationOllamaMarkdown (_pfx : String) (context : String) (prompts : List String)
(api : API) (options : ChatGenerationOptions) : IO $ Array (String × Float) := do
  let mut results : Std.HashSet String := Std.HashSet.emptyWithCapacity
  for prompt in prompts do
    for i in List.range options.numSamples do
      let temperature := if i == 1 then 0.0 else options.temperature
      let req : OllamaGenerationRequest := {
        model := api.model,
        prompt := prompt,
        stream := false,
        options := {
          temperature := temperature,
          num_predict := options.maxTokens,
          stop := options.stopSequences
        }
      }
      let res : OllamaResponse ← post req api.baseUrl api.key
      for tactic in (parseTacticResponseOllamaMarkdown context res) do
        results := results.insert (tactic)

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Ollama with tactic output (e.g., BFS-Prover)
-/
def tacticGenerationOllamaTactic (pfx : String) (prompts : List String)
(api : API) (options : ChatGenerationOptions) : IO $ Array (String × Float) := do
  let mut results : Std.HashSet String := Std.HashSet.emptyWithCapacity
  for prompt in prompts do
    for i in List.range options.numSamples do
      let temperature := if i == 1 then 0.0 else options.temperature
      let req : OllamaGenerationRequest := {
        model := api.model,
        prompt := prompt,
        stream := false,
        options := {
          temperature := temperature,
          num_predict := options.maxTokens,
          stop := options.stopSequences
        }
      }
      let res : OllamaResponse ← post req api.baseUrl api.key
      let tactic := res.response
      if tactic.startsWith pfx.trim then
        results := results.insert tactic

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Main Handler
-/

/--
Generates a list of tactics using the LLM API.
-/
def LLMlean.Config.API.tacticGeneration
  (api : API) (tacticState : String) (context : String)
  («prefix» : String) : CoreM $ Array (String × Float) := do
  let prompts := makePrompts api.promptKind context tacticState «prefix»
  let options ← getChatGenerationOptions api TacticKind.LLMStep
  match api.kind with
    | APIKind.Ollama =>
      match api.responseFormat with
      | ResponseFormat.Markdown =>
          tacticGenerationOllamaMarkdown «prefix» context prompts api options
      | ResponseFormat.Tactic =>
          tacticGenerationOllamaTactic «prefix» prompts api options
      | _ =>
          tacticGenerationOllama «prefix» prompts api options
    | APIKind.TogetherAI =>
      tacticGenerationOpenAI «prefix» prompts api options
    | APIKind.OpenAI =>
      tacticGenerationOpenAI «prefix» prompts api options
    | APIKind.Anthropic =>
      tacticGenerationAnthropic «prefix» prompts api options
    | APIKind.Codex =>
      tacticGenerationCodex «prefix» prompts api options

end LLMlean

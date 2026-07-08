/- Proof completion for LLMlean -/
import LLMlean.API.Common
import LLMlean.API.Prompts
import LLMlean.API.Codex.Completion

open Lean LLMlean.Config

namespace LLMlean

/--
Parses a proof out of a response from the LLM.
The proof is expected to be enclosed in `[PROOF]...[/PROOF]` tags.
-/
def splitProof (text : String) : String :=
  let text := ((text.splitOn "[PROOF]").tailD [text]).headD text
  match (text.splitOn "[/PROOF]").head? with
  | some s => s.trim
  | none => text.trim

def splitProofs (text : String) : Array String := Id.run do
  let parts := (text.splitOn "[PROOF]").tailD []
  let mut results : Array String := #[]
  for part in parts do
    match (part.splitOn "[/PROOF]").head? with
    | some proof =>
        let proof := proof.trim
        if proof.length > 0 then
          results := results.push proof
    | none => pure ()
  if results.isEmpty then
    let proof := splitProof text
    if proof.trim.length > 0 then
      return #[proof.trim]
    else
      return #[]
  else
    return results

/-!
## OpenAI
-/
def parseResponseQedOpenAI (res: OpenAIResponse) : Array String :=
  (res.choices.map fun x => (splitProof x.message.content)).toArray

def qedOpenAI (prompts : List String)
(api : API) (options : ChatGenerationOptionsQed) : IO $ Array (String × Float) := do
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
    for result in (parseResponseQedOpenAI res) do
      results := results.insert result

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Anthropic
-/
def parseResponseQedAnthropic (res: AnthropicResponse) : Array String :=
  (res.content.map fun x => (splitProof x.text)).toArray

def qedAnthropic (prompts : List String)
(api : API) (options : ChatGenerationOptionsQed) : IO $ Array (String × Float) := do
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
      for result in (parseResponseQedAnthropic res) do
        results := results.insert result

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Codex app-server
-/

def codexProofModel? (api : API) : Option String :=
  if api.model.trim == "" then none else some api.model

def codexMultiProofPrompt (prompt : String) (numSamples : Nat) : String :=
  if numSamples <= 1 then
    prompt
  else
    prompt ++ s!"

For this Codex app-server request, return up to {numSamples} distinct proof completions.
Put each candidate in its own [PROOF]...[/PROOF] block.
Each [PROOF] block must contain only Lean tactic script text.
Do not include explanations, comments, skill/tool mentions, or Markdown outside proof blocks."

def qedCodex (prompts : List String) (api : API) (options : ChatGenerationOptionsQed) :
    CoreM $ Array (String × Float) := do
  let some prompt := prompts.head?
    | return #[]
  Config.verbosePrint
    s!"Codex llmqed requested up to {options.numSamples} proof sample(s)"
  if options.numSamples > 1 then
    Config.verbosePrint
      s!"Codex llmqed currently uses one app-server turn; numSamples={options.numSamples} is a prompt-level request for multiple [PROOF] blocks, not {options.numSamples} independent Codex samples"
  let prompt := codexMultiProofPrompt prompt options.numSamples
  Config.verbosePrint s!"Codex llmqed prompt length: {prompt.length} characters"
  let response ← LLMlean.Codex.Completion.runConfiguredPrompt prompt (codexProofModel? api)
  Config.verbosePrint s!"Codex llmqed raw response:\n{response}"
  let parsedProofs := splitProofs response
  Config.verbosePrint s!"Codex parsed {parsedProofs.size} proof block(s)"
  for proof in parsedProofs do
    Config.verbosePrint s!"Parsed proof:\n{proof}"
  let mut results : Std.HashSet String := Std.HashSet.emptyWithCapacity
  let mut acceptedBeforeDedupe := 0
  let mut rejectedByBannedToken := 0
  for proof in parsedProofs do
    if filterGeneration proof then
      acceptedBeforeDedupe := acceptedBeforeDedupe + 1
      results := results.insert proof
    else
      rejectedByBannedToken := rejectedByBannedToken + 1
      Config.verbosePrint s!"Codex rejected proof because it contains a banned token:\n{proof}"
  let duplicateCount := acceptedBeforeDedupe - results.size
  Config.verbosePrint
    s!"Codex llmqed generation summary: requested={options.numSamples}, appServerTurns=1, parsed={parsedProofs.size}, bannedFiltered={rejectedByBannedToken}, deduped={duplicateCount}, returned={results.size}"
  if options.numSamples > 1 && results.size < options.numSamples then
    Config.verbosePrint
      s!"Codex returned fewer proofs than requested before Lean validation; current root cause is usually the single-turn prompt contract or candidate parsing/filtering, not the Infoview widget"
  return results.toArray.map fun proof => (proof, 1.0)

/-!
## Ollama
-/
def parseResponseQedOllama (res: OllamaResponse) : String :=
  splitProof res.response

def qedOllama (prompts : List String)
(api : API) (options : ChatGenerationOptionsQed) : IO $ Array (String × Float) := do
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
          stop := options.stopSequences,
          num_predict := options.maxTokens
        }
      }
      let res : OllamaResponse ← post req api.baseUrl api.key
      results := results.insert (parseResponseQedOllama res)

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Ollama with markdown output (e.g., Kimina Prover)
-/

/--
Extracts proof from markdown response by finding the last code block
and extracting content after the context.
-/
def extractProofFromMarkdownResponse (context : String) (response : String) : Option String := do
  let blocks := getMarkdownLeanCodeBlocks response
  let lastBlock ← blocks.getLast?

  -- Try to find where the context ends in the block
  -- First try: split by the entire context
  let splitByFullContext := lastBlock.splitOn context
  if splitByFullContext.length > 1 then
    -- Found the full context, return everything after it
    let proof := splitByFullContext[1]!.trim
    return proof

  -- Second try: find the last non-empty line of context and split by that
  let contextLines := context.splitOn "\n"
  let lastContextLine := (contextLines.filter (fun x => x.trim.length > 0)).getLast?.getD ""
  if lastContextLine.length > 0 then
    let splitByLastLine := lastBlock.splitOn lastContextLine
    if splitByLastLine.length > 1 then
      -- Found the last context line, return everything after it
      let proof := splitByLastLine[1]!.trim
      return proof

  -- If we can't find the context, return the whole block
  some lastBlock.trim

def qedOllamaMarkdown (prompts : List String) (context : String)
(api : API) (options : ChatGenerationOptionsQed) : IO $ Array (String × Float) := do
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
          stop := options.stopSequences,
          num_predict := options.maxTokens
        }
      }
      let res : OllamaResponse ← post req api.baseUrl api.key
      match extractProofFromMarkdownResponse context res.response with
      | some proof => results := results.insert proof
      | none => results := results

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Ollama with tactic output (e.g., BFS-Prover)
-/
def qedOllamaTactic (prompts : List String)
(api : API) (options : ChatGenerationOptionsQed) : IO $ Array (String × Float) := do
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
      results := results.insert tactic

  let finalResults := (results.toArray.filter filterGeneration).map fun x => (x, 1.0)
  return finalResults

/-!
## Main Handler
-/

/--
Generates proof completions using the LLM API.
-/
def LLMlean.Config.API.proofCompletion
  (api : API) (tacticState : String) (context : String) : CoreM $ Array (String × Float) := do
  let prompts := makeQedPrompts api.promptKind context tacticState
  let options ← getChatGenerationOptionsQed api TacticKind.LLMQed
  match api.kind with
    | APIKind.Ollama =>
      match api.responseFormat with
      | ResponseFormat.Markdown =>
        qedOllamaMarkdown prompts context api options
      | _ =>
        qedOllama prompts api options
    | APIKind.TogetherAI =>
      qedOpenAI prompts api options
    | APIKind.OpenAI =>
      qedOpenAI prompts api options
    | APIKind.Anthropic =>
      qedAnthropic prompts api options
    | APIKind.Codex =>
      qedCodex prompts api options

/--
Generates proof completions with refinement context using the LLM API.
-/
def LLMlean.Config.API.proofCompletionRefinement
  (api : API) (tacticState : String) (context : String)
  (previousAttempt : String) (errorMsg : String) : CoreM $ Array (String × Float) := do
  let prompts := makeQedRefinementPrompts api.promptKind context tacticState previousAttempt errorMsg
  let options ← getChatGenerationOptionsQed api TacticKind.LLMQed
  match api.kind with
    | APIKind.Ollama =>
      match api.responseFormat with
      | ResponseFormat.Markdown =>
        qedOllamaMarkdown prompts context api options
      | _ =>
        qedOllama prompts api options
    | APIKind.TogetherAI =>
      qedOpenAI prompts api options
    | APIKind.OpenAI =>
      qedOpenAI prompts api options
    | APIKind.Anthropic =>
      qedAnthropic prompts api options
    | APIKind.Codex =>
      qedCodex prompts api options

end LLMlean

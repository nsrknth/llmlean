import Mathlib
import LLMlean

set_option llmlean.api "codex"
set_option llmlean.codexCommand "codex app-server"
set_option llmlean.numSamples 3
set_option llmlean.verbose true
set_option llmlean.validateSuggestions true
set_option llmlean.codexReadTimeoutMs 30000
set_option llmlean.codexTurnTimeoutMs 180000

example {α : Type _} (r s t : Set α) : r ⊆ s → s ⊆ t → r ⊆ t := by
  llmstep ""

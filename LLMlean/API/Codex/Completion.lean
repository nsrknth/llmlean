/- Single-turn completion wrapper backed by Codex app-server. -/
import LLMlean.Config
import LLMlean.API.Codex.Client

open Lean

namespace LLMlean.Codex.Completion

open LLMlean.Codex.Client

def rejectApprovalPolicy : Json :=
  Json.mkObj [
    ("reject", Json.mkObj [
      ("sandbox_approval", true),
      ("rules", true),
      ("mcp_elicitations", true)
    ])
  ]

def readOnlyTurnSandboxPolicy : Json :=
  Json.mkObj [
    ("type", "readOnly"),
    ("networkAccess", false)
  ]

structure Options where
  cwd : Option System.FilePath := none
  title : Option String := none
  model : Option String := none
  readTimeoutMs : Nat := LLMlean.Config.defaultCodexReadTimeoutMs
  turnTimeoutMs : Nat := LLMlean.Config.defaultCodexTurnTimeoutMs
  approvalPolicy : Option Json := some rejectApprovalPolicy
  threadSandbox : Option Json := some ("read-only" : Json)
  turnSandboxPolicy : Option Json := some readOnlyTurnSandboxPolicy
  dynamicTools : Option (Array Json) := some #[]

def resolveCwd (options : Options) : IO System.FilePath := do
  match options.cwd with
  | some cwd => return cwd
  | none => IO.currentDir

def turnOutcomeError : TurnOutcome → String
  | .completed _ none => "Codex app-server completed the turn without final text"
  | .completed _ (some _) => "Codex app-server completed unexpectedly"
  | .failed _ => "Codex app-server turn failed"
  | .cancelled _ => "Codex app-server turn was cancelled"
  | .inputRequired _ => "Codex app-server turn requires input or approval"
  | .timedOut => "Codex app-server turn timed out"

def runPrompt (command : String) (prompt : String) (options : Options := {}) : IO String := do
  let cwd ← resolveCwd options
  let cwdString := cwd.toString
  withAppServer command (some cwd) fun server => do
    server.initialize options.readTimeoutMs
    let threadId ← server.startThread
      options.readTimeoutMs
      (cwd := some cwdString)
      (approvalPolicy := options.approvalPolicy)
      (sandbox := options.threadSandbox)
      (model := options.model)
      (dynamicTools := options.dynamicTools)
    discard <| server.startTurn
      options.readTimeoutMs
      threadId
      prompt
      (cwd := some cwdString)
      (title := options.title)
      (approvalPolicy := options.approvalPolicy)
      (sandboxPolicy := options.turnSandboxPolicy)
      (model := options.model)
    match ← server.awaitTurn options.turnTimeoutMs with
    | .completed _ (some text) => return text
    | outcome => throw <| IO.userError (turnOutcomeError outcome)

def firstSome (left : Option α) (right : Option α) : Option α :=
  match left with
  | some value => some value
  | none => right

def runConfiguredPrompt (prompt : String) (model : Option String := none) : CoreM String := do
  let command ← LLMlean.Config.getCodexCommand
  let readTimeoutMs ← LLMlean.Config.getCodexReadTimeoutMs
  let turnTimeoutMs ← LLMlean.Config.getCodexTurnTimeoutMs
  let configuredModel ← LLMlean.Config.getModel
  runPrompt command prompt {
    model := firstSome model configuredModel,
    readTimeoutMs := readTimeoutMs,
    turnTimeoutMs := turnTimeoutMs
  }

end LLMlean.Codex.Completion

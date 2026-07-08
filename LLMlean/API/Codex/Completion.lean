/- Single-turn completion wrapper backed by Codex app-server. -/
import LLMlean.Config
import LLMlean.API.Codex.Client
import LLMlean.API.Codex.Session

open Lean

namespace LLMlean.Codex.Completion

open LLMlean.Codex.Client

def defaultApprovalPolicy : Json :=
  ("never" : Json)

def readOnlyTurnSandboxPolicy : Json :=
  Json.mkObj [
    ("type", "readOnly"),
    ("networkAccess", false)
  ]

structure Options where
  cwd : Option System.FilePath := none
  title : Option String := none
  model : Option String := none
  effort : Option String := none
  debug : Bool := false
  readTimeoutMs : Nat := LLMlean.Config.defaultCodexReadTimeoutMs
  turnTimeoutMs : Nat := LLMlean.Config.defaultCodexTurnTimeoutMs
  approvalPolicy : Option Json := some defaultApprovalPolicy
  threadSandbox : Option Json := some ("read-only" : Json)
  turnSandboxPolicy : Option Json := some readOnlyTurnSandboxPolicy
  dynamicTools : Option (Array Json) := some #[]
  dynamicToolHandler? : Option DynamicToolHandler := none
  persistent : Bool := true

def debugPrint (options : Options) (message : String) : IO Unit := do
  if options.debug then
    IO.eprintln s!"[llmlean-codex] {message}"
  else
    pure ()

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

def wrapDynamicToolHandler (options : Options) : Option DynamicToolHandler :=
  options.dynamicToolHandler?.map fun dynamicToolHandler =>
    fun name arguments => do
      debugPrint options s!"dynamic tool requested: {name}"
      let result ← dynamicToolHandler name arguments
      match result with
      | .ok output =>
          debugPrint options
            s!"dynamic tool completed: {name}, outputLength={output.length}"
      | .error output =>
          debugPrint options
            s!"dynamic tool failed: {name}, outputLength={output.length}"
      return result

def toSessionOptions (options : Options) (cwd : System.FilePath) :
    LLMlean.Codex.Session.Options := {
  cwd := cwd,
  title := options.title,
  model := options.model,
  effort := options.effort,
  debug := options.debug,
  readTimeoutMs := options.readTimeoutMs,
  turnTimeoutMs := options.turnTimeoutMs,
  approvalPolicy := options.approvalPolicy,
  threadSandbox := options.threadSandbox,
  turnSandboxPolicy := options.turnSandboxPolicy,
  dynamicTools := options.dynamicTools,
  dynamicToolHandler? := options.dynamicToolHandler?
}

def runPromptOneShot (command : String) (prompt : String) (options : Options := {}) : IO String := do
  let cwd ← resolveCwd options
  let cwdString := cwd.toString
  let startedAt ← IO.monoMsNow
  debugPrint options s!"starting app-server command={command}, cwd={cwdString}"
  withAppServer command (some cwd) fun server => do
    debugPrint options s!"process started in {(← IO.monoMsNow) - startedAt}ms"
    server.initialize options.readTimeoutMs
    debugPrint options s!"initialized in {(← IO.monoMsNow) - startedAt}ms"
    let threadId ← server.startThread
      options.readTimeoutMs
      (cwd := some cwdString)
      (approvalPolicy := options.approvalPolicy)
      (sandbox := options.threadSandbox)
      (model := options.model)
      (dynamicTools := options.dynamicTools)
    debugPrint options s!"thread/start returned in {(← IO.monoMsNow) - startedAt}ms"
    discard <| server.startTurn
      options.readTimeoutMs
      threadId
      prompt
      (cwd := some cwdString)
      (title := options.title)
      (approvalPolicy := options.approvalPolicy)
      (sandboxPolicy := options.turnSandboxPolicy)
      (model := options.model)
      (effort := options.effort)
    debugPrint options s!"turn/start returned in {(← IO.monoMsNow) - startedAt}ms"
    match ← server.awaitTurn options.turnTimeoutMs
        (dynamicToolHandler? := wrapDynamicToolHandler options) with
    | .completed _ (some text) =>
        debugPrint options s!"turn completed in {(← IO.monoMsNow) - startedAt}ms"
        return text
    | outcome => throw <| IO.userError (turnOutcomeError outcome)

def runPrompt (command : String) (prompt : String) (options : Options := {}) : IO String := do
  let cwd ← resolveCwd options
  if options.persistent then
    LLMlean.Codex.Session.runPrompt command prompt (toSessionOptions options cwd)
  else
    runPromptOneShot command prompt { options with cwd := some cwd }

def firstSome (left : Option α) (right : Option α) : Option α :=
  match left with
  | some value => some value
  | none => right

def runConfiguredPrompt (prompt : String) (model : Option String := none) : CoreM String := do
  let command ← LLMlean.Config.getCodexCommand
  let readTimeoutMs ← LLMlean.Config.getCodexReadTimeoutMs
  let turnTimeoutMs ← LLMlean.Config.getCodexTurnTimeoutMs
  let configuredModel ← LLMlean.Config.getModel
  let effort ← LLMlean.Config.getCodexEffort
  let persistent ← LLMlean.Config.getCodexPersistent
  let options : Options := {
    model := firstSome model configuredModel,
    effort := effort,
    debug := (← LLMlean.Config.getVerbose),
    readTimeoutMs := readTimeoutMs,
    turnTimeoutMs := turnTimeoutMs,
    persistent := persistent
  }
  debugPrint options
    s!"turn config: model={options.model.getD "(default)"}, effort={options.effort.getD "(default)"}"
  runPrompt command prompt options

end LLMlean.Codex.Completion

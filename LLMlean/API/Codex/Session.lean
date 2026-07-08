/- Persistent Codex app-server session manager. -/
import Std.Sync.Mutex
import Lean.Elab.Command
import LLMlean.API.Codex.Client

open Lean

namespace LLMlean.Codex.Session

open LLMlean.Codex.Client

structure SessionKey where
  command : String
  cwd : String
  model : Option String
  approvalPolicyKey : String
  threadSandboxKey : String
  turnSandboxPolicyKey : String
  dynamicToolsKey : String
deriving BEq, Repr

structure Options where
  cwd : System.FilePath
  title : Option String := none
  model : Option String := none
  debug : Bool := false
  readTimeoutMs : Nat
  turnTimeoutMs : Nat
  approvalPolicy : Option Json := none
  threadSandbox : Option Json := none
  turnSandboxPolicy : Option Json := none
  dynamicTools : Option (Array Json) := some #[]

structure LiveSession where
  key : SessionKey
  server : AppServer
  threadId : String
  nextRequestId : Nat
  startedAtMs : Nat
  lastUsedAtMs : Nat

initialize sessionMutex : Std.Mutex (Option LiveSession) ← Std.Mutex.new none

def debugPrint (options : Options) (message : String) : IO Unit := do
  if options.debug then
    IO.eprintln s!"[llmlean-codex] {message}"
  else
    pure ()

def jsonOptionKey : Option Json → String
  | some json => json.compress
  | none => ""

def jsonArrayOptionKey : Option (Array Json) → String
  | some values => Json.arr values |>.compress
  | none => ""

def sessionKey (command : String) (options : Options) : SessionKey :=
  let cwdString := options.cwd.toString
  {
    command := command,
    cwd := cwdString,
    model := options.model,
    approvalPolicyKey := jsonOptionKey options.approvalPolicy,
    threadSandboxKey := jsonOptionKey options.threadSandbox,
    turnSandboxPolicyKey := jsonOptionKey options.turnSandboxPolicy,
    dynamicToolsKey := jsonArrayOptionKey options.dynamicTools
  }

def turnOutcomeError : TurnOutcome → String
  | .completed _ none => "Codex app-server completed the turn without final text"
  | .completed _ (some _) => "Codex app-server completed unexpectedly"
  | .failed _ => "Codex app-server turn failed"
  | .cancelled _ => "Codex app-server turn was cancelled"
  | .inputRequired _ => "Codex app-server turn requires input or approval"
  | .timedOut => "Codex app-server turn timed out"

def startSession (command : String) (options : Options) (key : SessionKey) : IO LiveSession := do
  let startedAt ← IO.monoMsNow
  debugPrint options s!"starting persistent app-server command={command}, cwd={key.cwd}"
  let server ← Client.start command (some options.cwd)
  try
    debugPrint options s!"persistent process started in {(← IO.monoMsNow) - startedAt}ms"
    server.initialize options.readTimeoutMs
    debugPrint options s!"persistent initialized in {(← IO.monoMsNow) - startedAt}ms"
    let threadId ← server.startThread
      options.readTimeoutMs
      (cwd := some key.cwd)
      (approvalPolicy := options.approvalPolicy)
      (sandbox := options.threadSandbox)
      (model := options.model)
      (dynamicTools := options.dynamicTools)
    let now ← IO.monoMsNow
    debugPrint options s!"persistent thread/start returned in {now - startedAt}ms"
    return {
      key := key,
      server := server,
      threadId := threadId,
      nextRequestId := 3,
      startedAtMs := startedAt,
      lastUsedAtMs := now
    }
  catch error =>
    server.terminate
    throw error

def ensureSession (command : String) (options : Options) (current : Option LiveSession) :
    IO LiveSession := do
  let key := sessionKey command options
  match current with
  | some session =>
      if session.key == key then
        match ← session.server.exitedError? with
        | none =>
            debugPrint options s!"reusing persistent app-server thread={session.threadId}"
            return session
        | some message =>
            debugPrint options s!"discarding exited persistent app-server: {message}"
            startSession command options key
      else
        debugPrint options "discarding persistent app-server because session key changed"
        session.server.terminate
        startSession command options key
  | none =>
      startSession command options key

def runTurn (session : LiveSession) (prompt : String) (options : Options) :
    IO (String × LiveSession) := do
  let startedAt ← IO.monoMsNow
  let requestId := session.nextRequestId
  discard <| session.server.startTurn
    options.readTimeoutMs
    session.threadId
    prompt
    (requestId := requestId)
    (cwd := some session.key.cwd)
    (title := options.title)
    (approvalPolicy := options.approvalPolicy)
    (sandboxPolicy := options.turnSandboxPolicy)
    (model := options.model)
  debugPrint options
    s!"persistent turn/start id={requestId} returned in {(← IO.monoMsNow) - startedAt}ms"
  match ← session.server.awaitTurn options.turnTimeoutMs with
  | .completed _ (some text) =>
      let now ← IO.monoMsNow
      debugPrint options s!"persistent turn completed in {now - startedAt}ms"
      return (text, { session with nextRequestId := requestId + 1, lastUsedAtMs := now })
  | outcome =>
      throw <| IO.userError (turnOutcomeError outcome)

def runPrompt (command : String) (prompt : String) (options : Options) : IO String := do
  sessionMutex.atomically fun ref => do
    let current ← ref.get
    let session ← ensureSession command options current
    try
      let (text, session) ← runTurn session prompt options
      ref.set (some session)
      return text
    catch error =>
      debugPrint options s!"terminating persistent app-server after turn error: {error}"
      session.server.terminate
      ref.set none
      throw error

def stopCurrentSession : IO Unit := do
  sessionMutex.atomically fun ref => do
    match ← ref.get with
    | some session =>
        session.server.terminate
        ref.set none
    | none =>
        pure ()

def currentSessionSummary : IO String := do
  sessionMutex.atomically fun ref => do
    match ← ref.get with
    | some session =>
        return s!"active thread={session.threadId}, cwd={session.key.cwd}, command={session.key.command}, nextRequestId={session.nextRequestId}"
    | none =>
        return "no active Codex app-server session"

end LLMlean.Codex.Session

open Lean Elab Command

syntax "#llmlean_codex_status" : command
syntax "#llmlean_codex_reset" : command

elab "#llmlean_codex_status" : command => do
  logInfo (← liftIO LLMlean.Codex.Session.currentSessionSummary)

elab "#llmlean_codex_reset" : command => do
  liftIO LLMlean.Codex.Session.stopCurrentSession
  logInfo "stopped current Codex app-server session"

/- Process-backed JSONL client for Codex app-server. -/
import Init.Task
import LLMlean.API.Codex.Protocol

open Lean

namespace LLMlean.Codex.Client

open LLMlean.Codex.Protocol

structure AppServer where
  child : IO.Process.Child {
    stdin := IO.Process.Stdio.piped,
    stdout := IO.Process.Stdio.piped,
    stderr := IO.Process.Stdio.piped
  }

inductive TurnOutcome where
  | completed (message : Json) (finalText? : Option String)
  | failed (message : Json)
  | cancelled (message : Json)
  | inputRequired (message : Json)
  | timedOut
deriving BEq

private inductive LineRead where
  | line (line : String)
  | timeout

def shellCommand (command : String) : String × Array String :=
  if System.Platform.isWindows then
    ("cmd.exe", #["/C", command])
  else
    ("bash", #["-lc", command])

def start (command : String) (cwd : Option System.FilePath := none) : IO AppServer := do
  let shell := shellCommand command
  let child ← IO.Process.spawn {
    cmd := shell.1,
    args := shell.2,
    cwd := cwd,
    stdin := IO.Process.Stdio.piped,
    stdout := IO.Process.Stdio.piped,
    stderr := IO.Process.Stdio.piped,
    setsid := true
  }
  return { child := child }

def AppServer.send (server : AppServer) (message : Json) : IO Unit := do
  server.child.stdin.putStr (message.compress.push '\n')
  server.child.stdin.flush

def readLineBlocking (server : AppServer) : IO String :=
  server.child.stdout.getLine

/--
Reads one stdout line with a timeout. If this returns `none`, the blocked read task may still be
waiting on the process pipe; callers should terminate the app-server before reusing the client.
-/
def readLineWithTimeout (server : AppServer) (timeoutMs : Nat) : IO (Option String) := do
  if timeoutMs == 0 then
    return some (← readLineBlocking server)
  else
    let lineTask ← IO.asTask
      (do
        let line ← readLineBlocking server
        return LineRead.line line)
      Task.Priority.dedicated
    let timeoutTask ← IO.asTask
      (do
        IO.sleep (ms := timeoutMs.toUInt32)
        return LineRead.timeout)
      Task.Priority.dedicated
    match ← IO.waitAny [lineTask, timeoutTask] with
    | .ok (.line line) => return some line
    | .ok .timeout => return none
    | .error error => throw error

def parseMessage (line : String) : Except String Json :=
  Json.parse line

def AppServer.readMessage (server : AppServer) : IO Json := do
  let line ← readLineBlocking server
  match parseMessage line with
  | .ok message => return message
  | .error error => throw <| IO.userError s!"Malformed Codex app-server JSONL frame: {error}"

def AppServer.tryReadMessage (server : AppServer) (timeoutMs : Nat) : IO (Option Json) := do
  let some line ← readLineWithTimeout server timeoutMs
    | return none
  match parseMessage line with
  | .ok message => return some message
  | .error _ => return some (Json.mkObj [
      ("method", "__llmlean/nonJsonLine"),
      ("params", Json.mkObj [
        ("line", line)
      ])
    ])

def rpcErrorMessage (error : RpcError) : String :=
  match error.code with
  | some code => s!"Codex app-server error {code}: {error.message}"
  | none => s!"Codex app-server error: {error.message}"

def timeoutMessage (requestId : RequestId) (timeoutMs : Nat) : String :=
  s!"Timed out waiting {timeoutMs}ms for Codex app-server response id {requestId}"

partial def awaitResponseLoop
    (server : AppServer)
    (requestId : RequestId)
    (timeoutMs : Nat)
    (startedAt : Nat) : IO Json := do
  let readTimeout ←
    if timeoutMs == 0 then
      pure 0
    else
      let elapsed := (← IO.monoMsNow) - startedAt
      if elapsed >= timeoutMs then
        throw <| IO.userError (timeoutMessage requestId timeoutMs)
      else
        pure (timeoutMs - elapsed)
  let some message ← server.tryReadMessage readTimeout
    | throw <| IO.userError (timeoutMessage requestId timeoutMs)
  match errorFor? requestId message with
  | some error => throw <| IO.userError (rpcErrorMessage error)
  | none =>
      match resultFor? requestId message with
      | some result => return result
      | none => awaitResponseLoop server requestId timeoutMs startedAt

def AppServer.awaitResponse
    (server : AppServer)
    (requestId : RequestId)
    (timeoutMs : Nat) : IO Json := do
  awaitResponseLoop server requestId timeoutMs (← IO.monoMsNow)

def AppServer.initialize
    (server : AppServer)
    (timeoutMs : Nat)
    (requestId : RequestId := 1) : IO Unit := do
  server.send (initializeRequest requestId)
  discard <| server.awaitResponse requestId timeoutMs
  server.send initializedNotification

def AppServer.startThread
    (server : AppServer)
    (timeoutMs : Nat)
    (requestId : RequestId := 2)
    (cwd : Option String := none)
    (approvalPolicy : Option Json := none)
    (sandbox : Option Json := none)
    (model : Option String := none)
    (dynamicTools : Option (Array Json) := some #[]) : IO String := do
  server.send <| threadStartRequest requestId cwd approvalPolicy sandbox model dynamicTools
  let result ← server.awaitResponse requestId timeoutMs
  match threadIdFromResult? result with
  | some threadId => return threadId
  | none => throw <| IO.userError "Codex app-server thread/start response did not include thread.id"

def AppServer.startTurn
    (server : AppServer)
    (timeoutMs : Nat)
    (threadId : String)
    (prompt : String)
    (requestId : RequestId := 3)
    (cwd : Option String := none)
    (title : Option String := none)
    (approvalPolicy : Option Json := none)
    (sandboxPolicy : Option Json := none)
    (model : Option String := none)
    (outputSchema : Option Json := none) : IO String := do
  server.send <| turnStartRequest
    requestId threadId prompt cwd title approvalPolicy sandboxPolicy model outputSchema
  let result ← server.awaitResponse requestId timeoutMs
  match turnIdFromResult? result with
  | some turnId => return turnId
  | none => throw <| IO.userError "Codex app-server turn/start response did not include turn.id"

def approvalResponseFor? (message : Json) : Option Json := do
  let method ← method? message
  let id ← id? message
  if method == "item/commandExecution/requestApproval" then
    some (acceptForSessionResponse id)
  else if method == "item/fileChange/requestApproval" then
    some (acceptForSessionResponse id)
  else if method == "execCommandApproval" then
    some (approvedForSessionResponse id)
  else if method == "applyPatchApproval" then
    some (approvedForSessionResponse id)
  else
    none

def unsupportedToolMessage (toolName : Option String) : String :=
  match toolName with
  | some name => s!"Unsupported dynamic tool: \"{name}\"."
  | none => "Unsupported dynamic tool call."

def AppServer.maybeRejectUnsupportedToolCall (server : AppServer) (message : Json) : IO Bool := do
  if hasMethod message "item/tool/call" then
    match id? message with
    | some requestId =>
        let params := (params? message).getD emptyParams
        let toolName := toolCallName? params
        server.send (dynamicToolFailure requestId (unsupportedToolMessage toolName))
        return true
    | none => return false
  else
    return false

def appendAgentText (accumulated : String) (message : Json) : String :=
  match agentTextUpdate? message with
  | some text => accumulated ++ text
  | none => accumulated

def completedText? (message : Json) (accumulated : String) : Option String :=
  match finalAgentMessage? message with
  | some text => some text
  | none =>
      if accumulated.trim.length > 0 then
        some accumulated
      else
        none

partial def awaitTurnLoop
    (server : AppServer)
    (timeoutMs : Nat)
    (startedAt : Nat)
    (autoApprove : Bool)
    (accumulated : String) : IO TurnOutcome := do
  let readTimeout ←
    if timeoutMs == 0 then
      pure 0
    else
      let elapsed := (← IO.monoMsNow) - startedAt
      if elapsed >= timeoutMs then
        return TurnOutcome.timedOut
      else
        pure (timeoutMs - elapsed)
  let some message ← server.tryReadMessage readTimeout
    | return TurnOutcome.timedOut
  let accumulated := appendAgentText accumulated message
  if turnCompleted? message then
    return TurnOutcome.completed message (completedText? message accumulated)
  else if turnFailed? message then
    return TurnOutcome.failed message
  else if turnCancelled? message then
    return TurnOutcome.cancelled message
  else if ← server.maybeRejectUnsupportedToolCall message then
    awaitTurnLoop server timeoutMs startedAt autoApprove accumulated
  else
    match approvalResponseFor? message with
    | some response =>
        if autoApprove then
          server.send response
          awaitTurnLoop server timeoutMs startedAt autoApprove accumulated
        else
          return TurnOutcome.inputRequired message
    | none =>
        if needsInput? message then
          return TurnOutcome.inputRequired message
        else
          awaitTurnLoop server timeoutMs startedAt autoApprove accumulated

def AppServer.awaitTurn
    (server : AppServer)
    (timeoutMs : Nat)
    (autoApprove : Bool := false) : IO TurnOutcome := do
  awaitTurnLoop server timeoutMs (← IO.monoMsNow) autoApprove ""

def TurnOutcome.finalText? : TurnOutcome → Option String
  | .completed _ text => text
  | _ => none

def AppServer.terminate (server : AppServer) : IO Unit := do
  match ← server.child.tryWait with
  | some _ => pure ()
  | none => server.child.kill

def AppServer.wait (server : AppServer) : IO UInt32 :=
  server.child.wait

def withAppServer
    (command : String)
    (cwd : Option System.FilePath := none)
    (body : AppServer → IO α) : IO α := do
  let server ← start command cwd
  try
    body server
  finally
    server.terminate

end LLMlean.Codex.Client

/- Process-backed JSONL client for Codex app-server. -/
import Init.Task
import Std.Sync.Channel
import LLMlean.API.Codex.Protocol

open Lean

namespace LLMlean.Codex.Client

open LLMlean.Codex.Protocol

inductive ReaderEvent where
  | line (line : String)
  | error (message : String)

structure AppServer where
  child : IO.Process.Child {
    stdin := IO.Process.Stdio.piped,
    stdout := IO.Process.Stdio.piped,
    stderr := IO.Process.Stdio.piped
  }
  stdoutEvents : Std.CloseableChannel.Sync ReaderEvent

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

def sendReaderEvent
    (events : Std.CloseableChannel.Sync ReaderEvent)
    (event : ReaderEvent) : IO Bool := do
  try
    Std.CloseableChannel.Sync.send events event
    return true
  catch _ =>
    return false

def closeReaderEvents (events : Std.CloseableChannel.Sync ReaderEvent) : IO Unit := do
  try
    Std.CloseableChannel.Sync.close events
  catch _ =>
    pure ()

partial def readStdoutLoop
    (stdout : IO.FS.Handle)
    (events : Std.CloseableChannel.Sync ReaderEvent) : IO Unit := do
  try
    let line ← stdout.getLine
    if ← sendReaderEvent events (.line line) then
      readStdoutLoop stdout events
    else
      pure ()
  catch error =>
    discard <| sendReaderEvent events (.error s!"{error}")
    closeReaderEvents events

def start (command : String) (cwd : Option System.FilePath := none) : IO AppServer := do
  let shell := shellCommand command
  let stdoutEvents ← Std.CloseableChannel.Sync.new
  let child ← IO.Process.spawn {
    cmd := shell.1,
    args := shell.2,
    cwd := cwd,
    stdin := IO.Process.Stdio.piped,
    stdout := IO.Process.Stdio.piped,
    stderr := IO.Process.Stdio.piped,
    setsid := true
  }
  discard <| IO.asTask (readStdoutLoop child.stdout stdoutEvents) Task.Priority.dedicated
  return { child := child, stdoutEvents := stdoutEvents }

def AppServer.send (server : AppServer) (message : Json) : IO Unit := do
  server.child.stdin.putStr (message.compress.push '\n')
  server.child.stdin.flush

def AppServer.readStderrBestEffort (server : AppServer) : IO String := do
  try
    return (← server.child.stderr.readToEnd).trim
  catch _ =>
    return ""

def AppServer.exitedError? (server : AppServer) : IO (Option String) := do
  try
    match ← server.child.tryWait with
    | none => return none
    | some exitCode =>
        let stderr ← server.readStderrBestEffort
        let detail :=
          if stderr.isEmpty then
            ""
          else
            s!": {stderr}"
        return some s!"Codex app-server exited with code {exitCode}{detail}"
  catch error =>
    let stderr ← server.readStderrBestEffort
    let detail :=
      if stderr.isEmpty then
        ""
      else
        s!": {stderr}"
    return some s!"Codex app-server exited before it produced a JSON response ({error}){detail}"

def stdoutClosedMessage : String :=
  "Codex app-server stdout closed before it produced a JSON response"

def AppServer.readerEventAsLine (server : AppServer) (event : ReaderEvent) : IO String := do
  match event with
  | .line line => return line
  | .error message =>
      match ← server.exitedError? with
      | some message => throw <| IO.userError message
      | none => throw <| IO.userError s!"Codex app-server stdout reader failed: {message}"

def AppServer.readLineBlocking (server : AppServer) : IO String := do
  match ← Std.CloseableChannel.Sync.recv server.stdoutEvents with
  | some event => server.readerEventAsLine event
  | none =>
      match ← server.exitedError? with
      | some message => throw <| IO.userError message
      | none => throw <| IO.userError stdoutClosedMessage

partial def readLinePollLoop
    (server : AppServer)
    (deadlineMs : Nat)
    (sleepMs : UInt32 := 10) : IO (Option String) := do
  match ← Std.CloseableChannel.Sync.tryRecv server.stdoutEvents with
  | some event => some <$> server.readerEventAsLine event
  | none =>
      match ← server.exitedError? with
      | some message => throw <| IO.userError message
      | none =>
          let now ← IO.monoMsNow
          if now >= deadlineMs then
            return none
          else
            IO.sleep sleepMs
            readLinePollLoop server deadlineMs sleepMs

def readLineWithTimeout (server : AppServer) (timeoutMs : Nat) : IO (Option String) := do
  if timeoutMs == 0 then
    some <$> server.readLineBlocking
  else
    readLinePollLoop server ((← IO.monoMsNow) + timeoutMs)

def parseMessage (line : String) : Except String Json :=
  Json.parse line

def AppServer.readMessage (server : AppServer) : IO Json := do
  let line ← server.readLineBlocking
  match parseMessage line with
  | .ok message => return message
  | .error error => throw <| IO.userError s!"Malformed Codex app-server JSONL frame: {error}"

def AppServer.tryReadMessage (server : AppServer) (timeoutMs : Nat) : IO (Option Json) := do
  let some line ← readLineWithTimeout server timeoutMs
    | return none
  if line.trim.isEmpty then
    match ← server.exitedError? with
    | some message => throw <| IO.userError message
    | none => pure ()
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
    | do
        match ← server.exitedError? with
        | some message => throw <| IO.userError message
        | none => throw <| IO.userError (timeoutMessage requestId timeoutMs)
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
  try
    match ← server.child.tryWait with
    | some _ => pure ()
    | none => server.child.kill
  catch _ =>
    pure ()
  closeReaderEvents server.stdoutEvents

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

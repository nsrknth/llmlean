import LLMlean.API.Codex.Session

def tracePath : System.FilePath :=
  "/tmp/llmlean-codex-persistent-busy-smoke.jsonl"

def fakeCommand : String :=
  s!"python3 Manual/fake_codex_silent_app_server.py {tracePath}"

def containsSubstring (text : String) (needle : String) : Bool :=
  (text.splitOn needle).length > 1

def assertContains (label text needle : String) : IO Unit := do
  unless containsSubstring text needle do
    throw <| IO.userError s!"{label}: expected to contain {needle}, got {text}"

partial def waitForTraceContaining (needle : String) : Nat → IO Unit
  | 0 => throw <| IO.userError s!"trace did not contain {needle}"
  | attempts + 1 => do
      let trace ←
        try
          IO.FS.readFile tracePath
        catch _ =>
          pure ""
      if containsSubstring trace needle then
        pure ()
      else
        IO.sleep 20
        waitForTraceContaining needle attempts

def options (cwd : System.FilePath) : LLMlean.Codex.Session.Options := {
  cwd := cwd,
  debug := true,
  readTimeoutMs := 5000,
  turnTimeoutMs := 500,
  approvalPolicy := some ("never" : Lean.Json),
  threadSandbox := some ("read-only" : Lean.Json),
  turnSandboxPolicy := some <| Lean.Json.mkObj [
    ("type", "readOnly"),
    ("networkAccess", false)
  ],
  dynamicTools := some #[]
}

#eval do
  try
    IO.FS.removeFile tracePath
  catch _ =>
    pure ()

  let cwd ← IO.currentDir
  let firstTask ← IO.asTask
    (LLMlean.Codex.Session.runPrompt fakeCommand "first silent prompt" (options cwd))
    Task.Priority.dedicated
  waitForTraceContaining "\"method\":\"turn/start\"" 100

  try
    discard <| LLMlean.Codex.Session.runPrompt fakeCommand "second prompt" (options cwd)
    throw <| IO.userError "expected Codex app-server busy error"
  catch error =>
    assertContains "busy error" s!"{error}" "already running a turn"

  let firstResult ← IO.wait firstTask
  match firstResult with
  | .ok text =>
      throw <| IO.userError s!"expected first turn to time out, got {text}"
  | .error error =>
      assertContains "first timeout" s!"{error}" "Codex app-server turn timed out"

  let summary ← LLMlean.Codex.Session.currentSessionSummary
  assertContains "session reset after timeout" summary "no active"

  IO.println "persistent Codex busy smoke passed"

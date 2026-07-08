import LLMlean.API.Codex.Session

def tracePath : System.FilePath :=
  "/tmp/llmlean-codex-persistent-timeout-smoke.jsonl"

def fakeCommand : String :=
  s!"python3 Manual/fake_codex_silent_app_server.py {tracePath}"

def containsSubstring (text : String) (needle : String) : Bool :=
  (text.splitOn needle).length > 1

def assertContains (label text needle : String) : IO Unit := do
  unless containsSubstring text needle do
    throw <| IO.userError s!"{label}: expected to contain {needle}, got {text}"

def assertNatEq (label : String) (expected actual : Nat) : IO Unit := do
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {expected}, got {actual}"

def countContaining (needle : String) (lines : List String) : Nat :=
  (lines.filter fun line => containsSubstring line needle).length

#eval do
  try
    IO.FS.removeFile tracePath
  catch _ =>
    pure ()

  let cwd ← IO.currentDir
  let options : LLMlean.Codex.Session.Options := {
    cwd := cwd,
    debug := true,
    readTimeoutMs := 5000,
    turnTimeoutMs := 100,
    approvalPolicy := some ("never" : Lean.Json),
    threadSandbox := some ("read-only" : Lean.Json),
    turnSandboxPolicy := some <| Lean.Json.mkObj [
      ("type", "readOnly"),
      ("networkAccess", false)
    ],
    dynamicTools := some #[]
  }

  try
    discard <| LLMlean.Codex.Session.runPrompt fakeCommand "silent prompt" options
    throw <| IO.userError "expected Codex app-server turn timeout"
  catch error =>
    assertContains "timeout error" s!"{error}" "Codex app-server turn timed out"

  let summary ← LLMlean.Codex.Session.currentSessionSummary
  assertContains "session reset after timeout" summary "no active"

  let trace ← IO.FS.readFile tracePath
  let lines := (trace.splitOn "\n").filter fun (line : String) => line.trim.length > 0
  assertNatEq "process starts" 1 (countContaining "START" lines)
  assertNatEq "turn/start requests" 1 (countContaining "\"method\":\"turn/start\"" lines)

  IO.println "persistent Codex timeout smoke passed"

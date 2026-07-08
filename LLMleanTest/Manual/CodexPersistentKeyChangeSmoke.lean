import LLMlean.API.Codex.Session

def tracePath : System.FilePath :=
  "/tmp/llmlean-codex-persistent-key-change-smoke.jsonl"

def fakeCommand : String :=
  s!"python3 Manual/fake_codex_app_server.py {tracePath}"

def containsSubstring (text : String) (needle : String) : Bool :=
  (text.splitOn needle).length > 1

def countContaining (needle : String) (lines : List String) : Nat :=
  (lines.filter fun line => containsSubstring line needle).length

def assertNatEq (label : String) (expected actual : Nat) : IO Unit := do
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {expected}, got {actual}"

def assertStringEq (label expected actual : String) : IO Unit := do
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {expected}, got {actual}"

def baseOptions (cwd : System.FilePath) (model : Option String) : LLMlean.Codex.Session.Options := {
  cwd := cwd,
  model := model,
  debug := true,
  readTimeoutMs := 5000,
  turnTimeoutMs := 5000,
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
  let firstOptions := baseOptions cwd (some "model-a")
  let secondOptions := baseOptions cwd (some "model-b")

  let first ← LLMlean.Codex.Session.runPrompt fakeCommand "first prompt" firstOptions
  let second ← LLMlean.Codex.Session.runPrompt fakeCommand "second prompt" secondOptions
  LLMlean.Codex.Session.stopCurrentSession

  assertStringEq "first response" "response-1" first
  assertStringEq "second response" "response-1" second

  let trace ← IO.FS.readFile tracePath
  let lines := (trace.splitOn "\n").filter fun (line : String) => line.trim.length > 0
  assertNatEq "process starts after key change" 2 (countContaining "START" lines)
  assertNatEq "initialize requests after key change" 2 (countContaining "\"method\":\"initialize\"" lines)
  assertNatEq "thread/start requests after key change" 2 (countContaining "\"method\":\"thread/start\"" lines)
  assertNatEq "turn/start requests after key change" 2 (countContaining "\"method\":\"turn/start\"" lines)

  IO.println "persistent Codex key-change smoke passed"

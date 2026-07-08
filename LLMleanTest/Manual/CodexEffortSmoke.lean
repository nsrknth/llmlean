import LLMlean.API.Codex.Session

open Lean

def tracePath : System.FilePath :=
  "/tmp/llmlean-codex-effort-smoke.jsonl"

def fakeCommand : String :=
  s!"python3 Manual/fake_codex_app_server.py {tracePath}"

def containsSubstring (text : String) (needle : String) : Bool :=
  (text.splitOn needle).length > 1

def assertContains (label text needle : String) : IO Unit := do
  unless containsSubstring text needle do
    throw <| IO.userError s!"{label}: expected to contain {needle}, got {text}"

def assertStringEq (label expected actual : String) : IO Unit := do
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {expected}, got {actual}"

#eval do
  try
    IO.FS.removeFile tracePath
  catch _ =>
    pure ()

  LLMlean.Codex.Session.stopCurrentSession

  let cwd ← IO.currentDir
  let modelCatalog ← LLMlean.Codex.Session.listModelsRaw fakeCommand 5000 cwd
  assertContains "model catalog includes effort metadata" modelCatalog "\"supportedReasoningEfforts\""
  assertContains "model catalog includes xhigh effort" modelCatalog "\"reasoningEffort\":\"xhigh\""

  let options : LLMlean.Codex.Session.Options := {
    cwd := cwd,
    model := some "gpt-5.5",
    effort := some "xhigh",
    debug := true,
    readTimeoutMs := 5000,
    turnTimeoutMs := 5000,
    approvalPolicy := some ("never" : Json),
    threadSandbox := some ("read-only" : Json),
    turnSandboxPolicy := some <| Json.mkObj [
      ("type", "readOnly"),
      ("networkAccess", false)
    ]
  }

  let response ← LLMlean.Codex.Session.runPrompt fakeCommand "effort smoke prompt" options
  LLMlean.Codex.Session.stopCurrentSession

  assertStringEq "fake response" "response-1" response

  let trace ← IO.FS.readFile tracePath
  assertContains "model/list requested hidden models" trace "\"includeHidden\":true"
  assertContains "thread/start carried model" trace "\"method\":\"thread/start\""
  assertContains "turn/start carried model" trace "\"model\":\"gpt-5.5\""
  assertContains "turn/start carried effort" trace "\"effort\":\"xhigh\""

  IO.println "Codex effort smoke passed"

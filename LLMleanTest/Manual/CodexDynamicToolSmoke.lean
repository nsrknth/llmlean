import LLMlean.API.Codex.Session

open Lean
open LLMlean.Codex.Client
open LLMlean.Codex.Protocol

def tracePath : System.FilePath :=
  "/tmp/llmlean-codex-dynamic-tool-smoke.jsonl"

def fakeCommand : String :=
  s!"python3 Manual/fake_codex_tool_app_server.py {tracePath}"

def containsSubstring (text : String) (needle : String) : Bool :=
  (text.splitOn needle).length > 1

def assertContains (label text needle : String) : IO Unit := do
  unless containsSubstring text needle do
    throw <| IO.userError s!"{label}: expected to contain {needle}, got {text}"

def assertStringEq (label expected actual : String) : IO Unit := do
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {expected}, got {actual}"

def leanEchoToolSpec : Json :=
  Json.mkObj [
    ("name", "lean_echo"),
    ("description", "Echo text through Lean to prove Codex dynamic tool routing works."),
    ("inputSchema", Json.mkObj [
      ("type", "object"),
      ("additionalProperties", false),
      ("required", Json.arr #[("text" : Json)]),
      ("properties", Json.mkObj [
        ("text", Json.mkObj [
          ("type", "string")
        ])
      ])
    ])
  ]

def dynamicToolHandler : DynamicToolHandler := fun name arguments => do
  if name == "lean_echo" then
    match fieldString? arguments "text" with
    | some text => return .ok s!"lean:{text}"
    | none => return .error "lean_echo requires a text argument"
  else
    return .error s!"unexpected dynamic tool: {name}"

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
    turnTimeoutMs := 5000,
    approvalPolicy := some ("never" : Json),
    threadSandbox := some ("read-only" : Json),
    turnSandboxPolicy := some <| Json.mkObj [
      ("type", "readOnly"),
      ("networkAccess", false)
    ],
    dynamicTools := some #[leanEchoToolSpec],
    dynamicToolHandler? := some dynamicToolHandler
  }

  let response ← LLMlean.Codex.Session.runPrompt fakeCommand "call lean_echo" options
  LLMlean.Codex.Session.stopCurrentSession

  assertStringEq "dynamic tool response" "tool-output=lean:hello" response

  let trace ← IO.FS.readFile tracePath
  assertContains "thread/start advertised dynamic tool" trace "\"dynamicTools\""
  assertContains "tool response was sent" trace "\"id\":99"
  assertContains "tool response succeeded" trace "\"success\":true"

  IO.println "Codex dynamic tool smoke passed"

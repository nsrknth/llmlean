# Codex App-Server Architecture

This document describes the proposed architecture for integrating Codex app-server with LLMLean.
It is intentionally scoped to the smallest useful integration: make `llmqed` able to use Codex as
an app-server-native proof assistant, with Lean validation exposed as a Codex dynamic tool.

The goal is not to build a general Codex SDK in Lean. The goal is to let Codex use Lean as the
host runtime while proving the current goal.

## Summary

Codex app-server should be integrated as a `TacticM`-native backend for `llmqed`.

The current provider path in LLMLean is essentially:

```text
llmqed / llmstep
  -> build prompt
  -> send request to an LLM API
  -> parse text response
  -> validate returned candidates in Lean
  -> display valid suggestions
```

The Codex app-server path should be:

```text
llmqed
  -> start an app-server session
  -> create a Codex thread
  -> start a turn with goal/context
  -> expose Lean validation as a dynamic tool
  -> handle app-server events until turn completion
  -> parse final candidate proofs
  -> revalidate returned candidates in Lean
  -> display valid suggestions
```

This is the meaningful difference from treating Codex as another completion API. Codex can call
back into the host. For LLMLean, the host capability that matters is Lean's tactic checker.

## Non-Goals

The first implementation should not include:

- a general Codex SDK
- generated Lean bindings for the full app-server schema
- WebSocket transport
- MCP integration
- file edit approval flows
- command execution approval flows
- a dashboard or orchestration service
- persistent cross-file Codex sessions
- `llmstep` support
- broad app-server configuration UI

Those can be reconsidered after the `llmqed` path works and is useful.

## Current LLMLean Boundaries

Relevant current files:

- `LLMlean/Config.lean`
  - Defines `APIKind`, `API`, provider defaults, and config parsing.
- `LLMlean/API/Common.lean`
  - Defines shared request/response structures and `getConfiguredAPI`.
  - Defines the current `post` helper for request-response HTTP providers.
- `LLMlean/API/ProofGen.lean`
  - Defines `API.proofCompletion` and `API.proofCompletionRefinement`.
- `LLMlean/API/TacticGen.lean`
  - Defines `API.tacticGeneration`.
- `LLMlean/LLMqed.lean`
  - Runs `llmqed`, gets the current goal and file context, calls the configured backend, and displays
    suggestions.
- `LLMlean/LLMstep.lean`
  - Runs `llmstep` and defines `checkSuggestion`.
- `LLMlean/IterativeRefinement.lean`
  - Defines `checkProofCompletion`, `generateSingleProofAttempt`, and the current refinement loop.

The key architectural issue is that `API.proofCompletion` runs in `CoreM`, while Lean proof
validation lives naturally in `Elab.Tactic.TacticM`.

Codex app-server should not be forced entirely through `API.proofCompletion`, because the valuable
integration is dynamic tool calls into Lean's checker during the app-server turn.

## Core Design Choice

Add `APIKind.Codex` for configuration, but branch to a Codex-native path in `LLMqed.lean`.

Conceptually:

```text
def llmQedWithConfiguredBackend (ctx : String) (g : MVarId) :
    Elab.Tactic.TacticM (Array (Prod String Float)) := do
  let api := getConfiguredAPI Config.TacticKind.LLMQed
  match api.kind with
  | Config.APIKind.Codex =>
      Codex.runQed ctx g api
  | _ =>
      liftMetaMAtMain (llmQed ctx g)
```

The exact code will differ, but the boundary matters:

- non-Codex providers keep the existing `CoreM` request-response API path
- Codex uses a `TacticM` path so it can handle `lean_validate` tool calls

## Proposed File Layout

```text
LLMlean/API/Codex/Protocol.lean
LLMlean/API/Codex/Transport.lean
LLMlean/API/Codex/Tools.lean
LLMlean/API/Codex/Qed.lean
```

The modules are intentionally small.

### `Protocol.lean`

Owns the small JSON-RPC message helpers needed by LLMLean.

Responsibilities:

- construct `initialize`
- construct `initialized`
- construct `thread/start`
- construct `turn/start`
- construct JSON-RPC responses to app-server requests
- inspect a message for `id`, `method`, `result`, and `error`
- extract thread id from `thread/start` response
- extract turn id from `turn/start` response
- extract final assistant text or candidates from `turn/completed`

It should not try to encode the entire app-server protocol as Lean inductive types.

Recommended representation:

```lean
abbrev RequestId := Nat

structure RpcRequest where
  id : RequestId
  method : String
  params : Json

structure RpcNotification where
  method : String
  params : Json
```

Use `Json` for protocol-owned payloads. Keep typed structures only for LLMLean-owned payloads, such
as final candidate lists and dynamic tool results.

### `Transport.lean`

Owns app-server transport I/O.

First implementation:

```text
stdio subprocess transport
```

Lean has the primitives needed:

- `IO.Process.spawn`
- piped `stdin`
- piped `stdout`
- `IO.FS.Handle.putStr`
- `IO.FS.Handle.flush`
- `IO.FS.Handle.getLine`
- `Json.parse`
- `Json.compress`

Suggested interface:

```lean
structure AppServerTransport where
  send : Json -> IO Unit
  recv : IO Json
  close : IO Unit
```

The first transport can spawn the configured command. A later transport could speak to a persistent
Unix socket without changing the proof-generation logic.

The transport should treat the app-server wire format as newline-delimited JSON:

```text
send Json.compress message ++ "\n"
read one line
Json.parse line
```

### `Tools.lean`

Owns Codex dynamic tools implemented by Lean.

First and only initial tool:

```json
{
  "name": "lean_validate",
  "description": "Validate Lean tactic or proof candidates in the current goal without modifying state.",
  "inputSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": ["kind", "candidates"],
    "properties": {
      "kind": {
        "type": "string",
        "enum": ["proof", "tactic"]
      },
      "candidates": {
        "type": "array",
        "items": { "type": "string" }
      }
    }
  }
}
```

Handler behavior:

- `kind = "proof"`
  - run `checkProofCompletion` from `IterativeRefinement.lean`
- `kind = "tactic"`
  - run `checkSuggestion` from `LLMstep.lean`
- return one result per candidate
- include parse/typechecking error messages for failures
- never modify the Lean state

Example tool result payload:

```json
{
  "success": true,
  "contentItems": [
    {
      "type": "inputText",
      "text": "{\"results\":[{\"candidate\":\"simp\",\"status\":\"valid\",\"error\":null}]}"
    }
  ]
}
```

Tool output should be text JSON because app-server dynamic tools accept content items, not arbitrary
Lean values.

### `Qed.lean`

Owns the `llmqed` app-server session.

Responsibilities:

- build the Codex proof prompt
- start app-server transport
- run the app-server startup sequence
- start one Codex turn
- handle messages until the turn completes or fails
- dispatch `lean_validate`
- parse final candidates
- close the transport

This module should expose one main function:

```lean
def runQed (ctx : String) (goal : MVarId) (api : Config.API) :
    Elab.Tactic.TacticM (Array (Prod String Float))
```

The returned candidates must still pass the existing `addSuggestions'` validation path in
`LLMqed.lean`.

## App-Server State Machine

The app-server client should be a small explicit state machine.

```text
open transport
send initialize(id = 1)
await response id = 1
send initialized notification

send thread/start(id = 2)
await response id = 2
record thread_id

send turn/start(id = 3)
await response id = 3
record turn_id

loop:
  if message is item/tool/call:
    handle supported tool or return unsupported-tool result
    continue

  if message is item/agentMessage/delta:
    append delta to stream buffer
    continue

  if message is turn/completed:
    parse final candidates from turn payload or accumulated final text
    return candidates

  if message is approval or input request:
    decline, cancel, or fail according to policy

  otherwise:
    ignore or verbose-log notification
    continue

close transport
```

The client must not wait only for a final text message. App-server is bidirectional. It can send
server-to-client requests during a turn, including dynamic tool calls and approval requests.

## Startup Messages

### Initialize

Use app-server initialization with a client identity for LLMLean.

```json
{
  "method": "initialize",
  "id": 1,
  "params": {
    "clientInfo": {
      "name": "llmlean",
      "title": "LLMLean",
      "version": "0.1.0"
    },
    "capabilities": {
      "experimentalApi": true
    }
  }
}
```

`experimentalApi` is needed if the implementation uses experimental fields such as dynamic tools or
output schemas in the installed app-server version. If the installed schema stabilizes those fields,
this can be revisited.

### Thread Start

The thread should be scoped to the current Lean project.

```json
{
  "method": "thread/start",
  "id": 2,
  "params": {
    "cwd": "/absolute/path/to/project",
    "model": "optional-model-from-config",
    "approvalPolicy": {
      "reject": {
        "sandbox_approval": true,
        "rules": true,
        "mcp_elicitations": true
      }
    },
    "sandbox": "read-only",
    "dynamicTools": [
      {
        "name": "lean_validate",
        "description": "Validate Lean tactic or proof candidates in the current goal without modifying state.",
        "inputSchema": {}
      }
    ]
  }
}
```

Use exact payload fields supported by the installed app-server schema. Do not hard-code a large
local enum of policy shapes. Treat Codex-owned policy payloads as pass-through JSON.

### Turn Start

The turn carries the goal, context, and output contract.

```json
{
  "method": "turn/start",
  "id": 3,
  "params": {
    "threadId": "thread-id-from-thread-start",
    "cwd": "/absolute/path/to/project",
    "input": [
      {
        "type": "text",
        "text": "proof prompt goes here"
      }
    ],
    "sandboxPolicy": {
      "type": "readOnly",
      "networkAccess": false
    },
    "outputSchema": {
      "type": "object",
      "additionalProperties": false,
      "required": ["candidates"],
      "properties": {
        "candidates": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    }
  }
}
```

The exact `sandboxPolicy` shape should be checked against the installed app-server schema. The
important policy is no command/file side effects by default.

## Prompt Contract

The prompt should not ask Codex to modify files. It should ask Codex to return proof candidates.

Sketch:

```text
You are helping complete a Lean 4 proof for LLMLean.

Return only JSON matching the provided output schema:
{"candidates": ["..."]}

You may call the lean_validate tool to test proof candidates.
Do not edit files.
Do not run shell commands.
Do not ask for user input.

Current Lean context:
<context>

Current goal:
<goal>

Generate 3 to 5 proof candidates. Prefer candidates that lean_validate reports as proof_done.
```

If Codex calls `lean_validate`, the handler can return detailed error strings. Codex can then
revise before final output.

## Candidate Extraction

Candidate extraction should be defensive:

1. Prefer final `agentMessage` with phase `final_answer` when present in `turn/completed`.
2. Fall back to the last `agentMessage` in the completed turn payload.
3. Fall back to accumulated `item/agentMessage/delta` text.
4. Parse the selected text as JSON.
5. Extract `candidates : Array String`.
6. If JSON parsing fails, fall back to existing Markdown/code-block extraction only if useful.

The final display path should still validate candidates with `addSuggestions'`. Codex tool results
are useful guidance, not trusted proof certificates.

## Approval and Input Policy

LLMLean is an interactive proof assistant integration, not an autonomous coding worker. The first
implementation should not allow Codex to perform side effects.

Recommended policy:

- `item/commandExecution/requestApproval`
  - respond with decline or cancel
- `item/fileChange/requestApproval`
  - respond with decline or cancel
- legacy `execCommandApproval`
  - respond with denial
- legacy `applyPatchApproval`
  - respond with denial
- `mcpServer/elicitation/request`
  - respond with decline, or fail the turn
- `item/tool/requestUserInput`
  - answer with a fixed non-interactive response, or fail the turn
- unsupported `item/tool/call`
  - return `success=false` with a clear unsupported-tool message

The client must not stall indefinitely on any of these messages.

## Configuration

Minimal config additions:

```toml
api = "codex"
model = "gpt-5.4" # optional; omitted uses Codex defaults
codexCommand = "codex app-server"
codexReadTimeoutMs = 5000
codexTurnTimeoutMs = 120000
```

Environment variables:

```bash
LLMLEAN_API=codex
LLMLEAN_MODEL=gpt-5.4
LLMLEAN_CODEX_COMMAND='codex app-server'
LLMLEAN_CODEX_READ_TIMEOUT_MS=5000
LLMLEAN_CODEX_TURN_TIMEOUT_MS=120000
```

Lean options can mirror the same fields if desired:

```lean
set_option llmlean.api "codex"
set_option llmlean.model "gpt-5.4"
set_option llmlean.codexCommand "codex app-server"
```

Do not add rich policy configuration in the first pass. Keep policy conservative and hard-coded.

## Error Handling

Expected error cases:

- app-server command not found
- app-server exits before initialization
- initialize response has error
- thread/start response missing thread id
- turn/start response missing turn id
- malformed JSON line
- unexpected response id
- dynamic tool call has invalid input
- turn times out
- turn completes without parseable candidates
- app-server requests unsupported user input
- app-server requests command or file approval

Each error should become a Lean error message that explains:

- which app-server phase failed
- the app-server method or request id involved, if known
- the response error message, if app-server provided one

Verbose mode can include raw app-server notifications, but normal mode should stay quiet.

## Interaction With Existing Iterative Refinement

There are two possible designs.

### Preferred Initial Design

Codex handles refinement inside one app-server turn using `lean_validate`.

```text
Codex proposes candidate
Codex calls lean_validate
Lean returns errors
Codex revises
Codex returns final candidates
LLMLean revalidates
```

This avoids layering LLMLean's existing outer iterative loop on top of Codex's app-server turn loop.

### Later Design

Reuse one Codex thread across multiple `turn/start` calls.

```text
turn 1 -> candidates fail final LLMLean validation
turn 2 -> continuation prompt with exact Lean errors
turn 3 -> final candidates
```

This mirrors Symphony's continuation-turn pattern. It is useful if single-turn tool use is
insufficient, but it should not be part of the first slice.

## Why Not Put Everything Behind `API.proofCompletion`

`API.proofCompletion` is the right abstraction for completion providers:

```text
prompt -> response text
```

Codex app-server is a session protocol:

```text
thread -> turn -> notifications -> tool calls -> final state
```

Forcing Codex into `API.proofCompletion` would either:

- lose dynamic tool calls into Lean, or
- require passing `TacticM` capabilities through a `CoreM` API in an awkward way

The correct compromise is:

- add `APIKind.Codex` for config selection
- branch in `LLMqed.lean`
- keep existing provider APIs for existing providers

## Implementation Phases

### Phase 1: Minimal Native `llmqed`

Deliverables:

- `APIKind.Codex`
- Codex config fields
- stdio JSONL transport
- initialize/thread/start/turn/start protocol helpers
- one `lean_validate` dynamic tool
- one-turn `Codex.runQed`
- `llmqed` branch for `api = "codex"`
- final candidate extraction from JSON
- revalidation through existing `addSuggestions'`

This is the first useful milestone.

### Phase 2: Better Diagnostics

Deliverables:

- verbose app-server event tracing
- clearer Lean error messages
- timeout configuration
- raw response snippets on parse failure
- small fake app-server tests for protocol helpers

### Phase 3: Continuation Turns

Deliverables:

- keep one live thread for multiple turns during one `llmqed`
- feed final validation errors into a continuation turn
- cap continuation count
- stop on first proof-complete candidate

This should only happen after Phase 1 proves useful.

### Phase 4: Optional `llmstep`

`llmstep` can use the same transport and `lean_validate` tool, but its latency expectations are
different. It should not block the `llmqed` integration.

## Test Strategy

Tests should avoid requiring live Codex initially.

Suggested fake app-server tests:

- initialize response is matched by id
- `thread/start` payload includes `dynamicTools`
- `turn/start` payload includes `outputSchema`
- `item/tool/call` dispatches `lean_validate`
- unsupported tool returns `success=false`
- command approval request is declined or fails deterministically
- `turn/completed` with final JSON returns candidates
- malformed JSON reports a useful error
- timeout reports the current phase

Live Codex testing can be manual or opt-in because it depends on local authentication and installed
Codex version.

## Open Questions

- Should the initial transport run `codex app-server` directly, or run a configurable shell command?
  A configurable command is more flexible, but direct argv is less shell-sensitive.
- Should the first version use `outputSchema` unconditionally, or make it conditional on app-server
  experimental capability?
- Should approval/input requests fail the turn immediately, or return denial and let Codex continue?
  Denial is more graceful; immediate failure is easier to reason about.
- Should `lean_validate` accept one candidate or a list? A list is more efficient and encourages
  Codex to batch checks.
- Should final candidates include metadata from tool checks? The UI currently only needs strings and
  scores, so metadata can wait.

## Recommendation

Build Phase 1 only:

```text
Codex-native llmqed
stdio JSONL app-server client
one Lean dynamic tool: lean_validate
strict no-side-effect policy
JSON final candidates
existing LLMLean validation before display
```

This is the smallest architecture that is actually app-server-native. Anything smaller is just a
completion backend. Anything larger starts becoming a standalone Codex client.

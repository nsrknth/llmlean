# Codex App-Server Architecture

This document describes the Codex app-server integration direction for LLMLean after reviewing:

- the official Codex app-server manual section
- the official Codex speed section
- Symphony's app-server spec and Elixir implementation under
  `app-server-example-usage/symphony`
- the current LLMLean Codex spike in `LLMlean/API/Codex`

The current implementation is a useful protocol smoke test. It is not yet the right editor
architecture. The next architecture should keep a Codex app-server process and thread alive inside
the current Lean process after the first explicit LLM tactic invocation.

## Current Conclusion

Use Codex app-server as a session protocol, not as a per-request completion API.

The important distinction is:

```text
Completion-style backend:
  prompt -> HTTP/API request -> response text

Codex app-server backend:
  connection -> initialize -> thread -> turn -> event stream -> optional client tools -> completion
```

The current LLMLean spike still behaves like the first shape on every cache miss:

```text
llmstep / llmqed
  -> build prompt
  -> start `codex app-server`
  -> initialize
  -> thread/start
  -> turn/start
  -> await turn/completed
  -> parse final text
  -> terminate app-server
```

That is protocol-correct, but it throws away the thing app-server gives us: a live connection,
thread identity, streaming events, and reusable conversation state.

The revised target is:

```text
import LLMlean
  -> register options and create an empty session manager only

first explicit llmstep/llmqed using api = "codex"
  -> lazy-start `codex app-server`
  -> initialize once
  -> thread/start once for the current project/session
  -> turn/start for this suggestion request
  -> await turn/completed
  -> keep process and thread alive

later llmstep/llmqed in the same Lean process
  -> reuse the live app-server process
  -> reuse or resume the live thread
  -> start another turn
```

Do not start Codex at module import time. Import can allocate the session manager; it should not
start external processes or model turns.

## Why It Is Slow Today

There are four separate latency sources.

1. Codex model latency.

   Local measurements on simple Lean goals showed process startup, initialization, `thread/start`,
   and `turn/start` completing in well under a second, while the app-server turn itself took roughly
   20 to 25 seconds. Persistent sessions will not eliminate that whole cost.

2. Per-prompt app-server startup.

   Even though startup is not the dominant cost in the measured examples, repeatedly starting
   app-server is still wrong for an editor workflow. It adds fixed overhead, discards thread context,
   prevents useful continuation turns, and makes repeated Infoview refreshes feel heavier than
   necessary.

3. Lean editor elaboration churn.

   Lean can re-elaborate files as imports, options, and preceding declarations change. A live LLM
   tactic inside a normal build target can therefore trigger expensive turns during `lake build` or
   editor refresh, not only when the user mentally expects a suggestion.

4. Output contract and validation churn.

   If Codex returns prose or partial formatting, LLMLean still has to parse, filter, validate, and
   display suggestions. Bad extraction can make the user see one partial suggestion even when the
   model spent a full turn. Recent parser and verbose-log fixes reduce this, but they do not change
   model latency.

Persistent app-server sessions address item 2 and make item 3 easier to control. They do not, by
themselves, make a 20 second Codex turn become instant. For perceived speed, we also need prompt
discipline, caching, streaming diagnostics, and eventually a smaller/faster model or service tier
when available.

## Official App-Server Model

The official app-server docs describe Codex app-server as the interface for rich clients that need
authentication, history, approvals, and streamed agent events. They also explicitly distinguish
this from automation or CI jobs, where the Codex SDK is the recommended surface.

The important app-server lifecycle is:

```text
open transport
send initialize
send initialized
thread/start or thread/resume
turn/start
read notifications and server requests until turn/completed
```

The docs call out that clients should initialize once per connection, then use thread and turn APIs.
This strongly suggests an LLMLean client should not repeatedly create a fresh app-server connection
for every suggestion once the protocol spike is past the smoke-test phase.

The speed docs are relevant but secondary. Fast mode and faster Codex models may reduce model time
when the user's account, selected model, and Codex surface support them. They are not an architecture
substitute for a correct long-lived app-server client.

## Symphony Lessons

Symphony is the useful example because it uses app-server directly from Elixir without relying on a
language-native Codex SDK.

The most relevant design points:

- `start_session` starts the subprocess, initializes app-server, and creates a thread.
- `run_turn` starts a turn on an existing session.
- A worker can run continuation turns on the same live thread.
- The spec says the app-server subprocess should remain alive across continuation turns and stop
  only when the worker run ends.
- The test suite asserts this behavior: one `thread/start`, multiple `turn/start` calls for a
  continued worker run.
- The client keeps stream handling separate from higher-level orchestration. It emits structured
  events for notifications, turn completion, failures, malformed lines, token usage, and tool or
  approval handling.
- It uses large turn timeouts for real Codex work. The default in the Elixir schema is one hour,
  which is very different from treating every app-server turn like a short HTTP request.

The LLMLean equivalent should be smaller, but the shape is the same:

```text
session manager:
  owns process, connection, thread id, request ids, policy, cwd, model

suggestion request:
  sends one turn/start on the existing thread
  waits for turn terminal event
  parses candidates
```

## Why Not Start At `import LLMlean`

Starting Codex when the module is imported is the wrong boundary.

Lean imports happen during builds, editor server startup, dependency loading, and worker process
creation. They are not a user intent signal. If `import LLMlean` started `codex app-server`, then a
plain `lake build`, a downstream package import, or an editor restart could create external
processes and possibly begin auth/session work before any tactic is used.

What is safe at import/module initialization:

- register Lean options
- initialize `IO.Ref`s
- initialize a lock or serialized queue
- install syntax/elaborator declarations

What is not safe at import/module initialization:

- spawn `codex app-server`
- authenticate or open remote model sessions
- start app-server threads
- start turns
- run suggestions

The practical compromise is lazy startup:

```text
initialize codexSessionRef : IO.Ref (Option LiveSession) <- IO.mkRef none

on first explicit llmstep/llmqed with llmlean.api = "codex":
  if no compatible live session exists:
    start app-server
    initialize
    thread/start
  run turn/start
```

This keeps imports deterministic while still avoiding repeated spawn/initialize/thread work after
the user explicitly asks Codex for suggestions.

## Session Scope

The first persistent implementation should be scoped to one Lean process.

```text
scope:
  current Lean server or `lake env lean` process

not scope:
  global daemon shared across all projects
  persistent history across editor restarts
  shared process across unrelated cwd/model/policy combinations
```

A live session is compatible only when the important configuration matches:

- app-server command
- project cwd
- model
- approval policy
- thread sandbox
- turn sandbox policy shape
- dynamic tool set

If any of those change, the manager should start a new session or explicitly restart the old one.

## Session Manager Shape

The next implementation should introduce a real session manager beside the current one-shot wrapper.

Suggested module:

```text
LLMlean/API/Codex/Session.lean
```

Suggested structures:

```lean
structure SessionKey where
  command : String
  cwd : String
  model : Option String
  approvalPolicyKey : String
  threadSandboxKey : String
  turnSandboxPolicyKey : String
  dynamicToolsKey : String

structure LiveSession where
  key : SessionKey
  server : LLMlean.Codex.Client.AppServer
  threadId : String
  nextRequestId : Nat
  startedAtMs : Nat
  lastUsedAtMs : Nat
```

The exact Lean primitives for locking should be verified in code, but the behavior must be:

- at most one active turn per live session unless app-server concurrency is explicitly supported
- concurrent tactic elaborations are serialized or receive a clear "Codex busy" error
- session replacement terminates the old process
- process exit is detected and clears the stored session
- a manual restart option can force a new process and thread

Possible user-facing options:

```lean
set_option llmlean.codexPersistent true
set_option llmlean.codexCache true
set_option llmlean.codexTurnTimeoutMs 180000
```

The default can remain conservative while the feature is experimental, but the architecture should
be persistent-first.

## One-Shot Wrapper Role

The existing wrapper in `LLMlean/API/Codex/Completion.lean` should not be deleted immediately.

Keep it for:

- protocol smoke tests
- fake app-server tests
- fallback when persistent sessions are disabled
- isolating failures during development

But production editor use should move from:

```lean
withAppServer command cwd fun server => ...
```

to:

```lean
withCodexSession key fun session => ...
```

where `withCodexSession` reuses the existing process and thread whenever possible.

## Turn Handling

A reused session still starts a new turn for each suggestion request.

```text
turn/start:
  threadId = stored thread id
  cwd = current project cwd
  input = current goal/context prompt
  title = optional short file/line/goal title
  approvalPolicy = conservative policy
  sandboxPolicy = read-only by default
```

The client must continue reading the app-server stream until a terminal turn event:

- `turn/completed`
- `turn/failed`
- `turn/cancelled`
- timeout
- subprocess exit
- required input or approval that LLMLean cannot satisfy

While waiting, it should handle:

- `item/agentMessage/delta`: accumulate text and optionally verbose-log progress
- `thread/tokenUsage/updated`: verbose-log token accounting
- unsupported `item/tool/call`: return a clear failure result and keep reading
- command/file approval requests: decline or fail according to policy
- malformed non-protocol lines: verbose-log, do not crash unless they block protocol progress

## Prompting and Candidate Extraction

For the current completion-style spike, ask Codex for multiple tactics in a strict format:

```text
[TAC]
...
[/TAC]

[TAC]
...
[/TAC]
```

This is more robust than asking for prose or a single fenced code block. LLMLean should keep the
defensive extraction rules:

- prefer explicit `[TAC]...[/TAC]` blocks
- accept fenced Lean code blocks when useful
- ignore prose-only responses
- filter candidates that do not look like Lean tactics
- verbose-log raw response, parsed count, and kept candidates when `llmlean.verbose = true`

Final display still depends on Lean-side validation. Codex output is a suggestion source, not a
proof certificate.

## Dynamic Lean Tooling

The truly app-server-native design is still to expose Lean validation as a client-side Codex tool.
That should come after the lifecycle is fixed.

Initial tool:

```json
{
  "name": "lean_validate",
  "description": "Validate Lean tactic or proof candidates in the current goal without modifying state.",
  "inputSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": ["kind", "candidates"],
    "properties": {
      "kind": { "type": "string", "enum": ["proof", "tactic"] },
      "candidates": { "type": "array", "items": { "type": "string" } }
    }
  }
}
```

This requires a `TacticM`-native path because the useful validation context is the current Lean
goal. A pure `CoreM` completion wrapper cannot naturally service this tool. The persistent session
manager can be shared, but `llmstep` and `llmqed` should call it from tactic elaborators when dynamic
tools are enabled.

Tool responses should include:

- candidate string
- parse status
- elaboration/check result
- concise error text
- whether the candidate closes the goal

Even if Codex used `lean_validate`, LLMLean must revalidate before displaying or accepting a
candidate.

## Build And Test Policy

Do not leave live Codex tactics in files that are part of the default build target.

Live files such as:

```text
LLMleanTest/Manual/CodexLLMStep.lean
```

are the right home for interactive Infoview experiments. Build-target example files should use
ordinary Lean proofs, `sorry`, or disabled examples. Otherwise `lake build` can trigger real Codex
turns and fail because of timeout, auth, or network state.

Suggested tests:

- pure protocol JSON tests
- fake app-server process tests for initialize/thread/start/turn/start
- fake continuation test proving one `thread/start` and multiple `turn/start`
- parser smoke tests under `LLMleanTest/Manual` or a non-live test target
- manual live Codex Infoview file for human verification

Live Codex tests should remain opt-in because they depend on local Codex authentication, installed
Codex version, account/model availability, and network state.

## Diagnostics

Verbose mode should make the latency and extraction pipeline visible:

- cache hit or miss
- whether persistent session was reused or started
- startup, initialize, thread/start, turn/start, and turn completion timings
- raw app-server errors
- streamed agent text snippets or final text
- parsed candidate count
- candidate validation result labels
- displayed suggestion count
- token usage events when app-server emits them

This is necessary for editor debugging. Without it, a slow or malformed Codex response looks like an
LLMLean tactic bug.

## Revised Implementation Phases

### Phase 0: Protocol Spike

Status: implemented.

Implemented pieces:

- `APIKind.Codex`
- app-server JSON helpers
- process-backed JSONL client
- single-turn completion wrapper
- Codex path wired into `llmstep` and `llmqed`
- response cache for identical prompts in the current Lean process
- multi-candidate tactic parsing
- verbose extraction and validation logs

This proves app-server can be driven from Lean, but it is still one-shot.

### Phase 1: Lazy Persistent Session

Next best step.

Deliverables:

- `LLMlean/API/Codex/Session.lean`
- process/thread reuse across multiple Codex turns in one Lean process
- serialized access to a live session
- compatibility key for command/cwd/model/policy/tool set
- explicit restart/cleanup path
- verbose logs showing reuse vs startup
- fake app-server regression test:
  - one `initialize`
  - one `thread/start`
  - two `turn/start` calls across two suggestions

Acceptance criterion:

```text
Two sequential Codex suggestions in one Lean process should not spawn two app-server processes and
should not send two thread/start requests for the same compatible session.
```

### Phase 2: Editor-Safe Controls

Deliverables:

- keep live experiments under `LLMleanTest/Manual`
- document that default builds should not execute live Codex tactics
- clearer errors for "Codex busy", timeout, process exit, and required input
- optional idle timeout or manual restart command
- stable verbose logs for Infoview and CLI builds

### Phase 3: Tactic-Native Dynamic Tool

Deliverables:

- `lean_validate` dynamic tool
- `llmstep` TacticM-native Codex path
- `llmqed` TacticM-native Codex path
- Codex can test candidates during the turn
- final suggestions still revalidated by LLMLean

This is where app-server becomes meaningfully better than a completion backend.

### Phase 4: Streaming UI And Faster Feedback

Deliverables:

- stream partial app-server events into a useful Lean message or widget path when feasible
- show "thinking/streaming" state instead of silent waiting
- expose token usage and elapsed time in verbose mode
- evaluate faster Codex model/service-tier options separately from architecture

## Open Questions

- Should the default persistent session be enabled immediately, or guarded by
  `llmlean.codexPersistent` during stabilization?
- Should a session be per project cwd or per Lean file? Project cwd is simpler and closer to
  app-server's thread model.
- Should `llmstep` and `llmqed` share the same thread? Sharing improves context reuse; separate
  threads may avoid confusing proof-completion and next-tactic prompts.
- What Lean locking primitive should be used for portable serialized access?
- Should an idle timeout kill app-server after several minutes, or should it live until the Lean
  process exits?
- How should users manually restart the session from Lean/Infoview if Codex state becomes stale?

## Recommendation

Implement Phase 1 next.

Do not start Codex at `import LLMlean`. Start it lazily on the first explicit Codex-backed
`llmstep` or `llmqed`, keep the process and thread alive for subsequent suggestions in the same
Lean process, and verify the behavior with a fake app-server test before adding dynamic Lean tools.

That is the smallest change that aligns LLMLean with the official app-server lifecycle and
Symphony's successful app-server usage pattern.

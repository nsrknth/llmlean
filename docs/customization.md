### Configurations

The following configurations let you customize LLMLean. Each variable can be set in the configuration file `~/.config/llmlean/config.toml` (or `C:\Users\<Username>\AppData\Roaming\llmlean\config.toml` on Windows).

#### LLM in the cloud
Example:

- `api`:
  - `together` : to use Together.ai API
  - `openai` : to use OpenAI API
  - `anthropic` : to use Anthropic API
- `apiKey`:
  - E.g. [API key](https://api.together.xyz/settings/api-keys) for Together API, or OpenAI / Anthropic API key
- `endpoint`: API endpoint
  - E.g. `https://api.together.xyz/v1/completions` for Together API
- `prompt`:
  - `fewshot`: for base models
  - `instruction`: for instruction-tuned models
- `model`:
  - Example for Together API: `mistralai/Mixtral-8x7B-Instruct-v0.1`
  - Example for Open AI: `gpt-4o`
  - Example for Anthropic: `claude-3-7-sonnet-20250219`
- `numSamples`:
  - Example: `10`
- `mode`:
  - `parallel`: Generate multiple proof attempts in parallel
  - `iterative`: Generate and refine proofs based on error feedback
- `maxIterations`:
  - Number of refinement iterations in iterative mode (e.g., `3`)
- `verbose`:
  - `true`: Show detailed LLM interaction and refinement steps

Set each variable in the configuration file, as indicated in [README](../README.md). Alternatively, set environment variables `LLMLEAN_API`, `LLMLEAN_API_KEY`, `LLMLEAN_ENDPOINT`, `LLMLEAN_PROMPT`, `LLMLEAN_MODEL`, `LLMLEAN_NUM_SAMPLES`, `LLMLEAN_MODE`, `LLMLEAN_MAX_ITERATIONS`, and `LLMLEAN_VERBOSE` respectively, or enter `set_option llmlean.<relevant-config> <value>` before `llmstep`/`llmqed` is called.

**Note on Iterative Refinement**: This mode works particularly well with models that can understand and learn from error messages. We recommend using instruction-tuned models with the `reasoning` prompt type for best results.

#### Codex app-server (experimental)

The `codex` API kind uses Codex app-server through the current experimental provider path. By
default it lazy-starts app-server on the first explicit Codex-backed tactic call, reuses the same
process/thread for later compatible turns in the current Lean process, parses returned suggestions,
and then validates them in Lean before display. See
[codex-app-server-architecture.md](codex-app-server-architecture.md) for details.

Configuration variables:

- `api`:
  - `codex`: select the Codex app-server backend
- `codexCommand`:
  - Command used to start app-server, defaulting to `codex app-server`
- `codexReadTimeoutMs`:
  - Timeout for app-server request/response handshakes, defaulting to `5000`
- `codexTurnTimeoutMs`:
  - Timeout for one Codex turn, defaulting to `120000`. If a persistent Codex turn times out,
    LLMLean terminates the app-server process and clears the cached session.
- `codexPersistent`:
  - Reuse one app-server process/thread across compatible prompts in the current Lean process,
    defaulting to `true`

Environment variables:

```bash
export LLMLEAN_API=codex
export LLMLEAN_CODEX_COMMAND='codex app-server'
export LLMLEAN_CODEX_READ_TIMEOUT_MS=5000
export LLMLEAN_CODEX_TURN_TIMEOUT_MS=120000
export LLMLEAN_CODEX_PERSISTENT=true
```

Lean commands:

```lean
#llmlean_codex_status
#llmlean_codex_reset
```

Use `#llmlean_codex_reset` to stop the currently cached app-server process/thread. The next
Codex-backed `llmstep` or `llmqed` starts a fresh session.

If another Codex tactic is already running in the same Lean process, a second persistent Codex
request fails fast with a "session is already running a turn" error instead of waiting behind it.

With `llmlean.verbose = true`, the Codex path logs whether the session was started or reused,
request timings, raw response text, parsed suggestion counts, validation results, and displayed
suggestion counts.

#### LLM on your laptop
- `api`:
  - `ollama` : to use ollama (default)
- `endpoint`:
  - With ollama it is `http://localhost:11434/api/generate`
- `prompt`:
  - `fewshot`: for base models
  - `instruction`: for instruction-tuned models
- `model`:
  - Example: `solobsd/llemma-7b`
- `numSamples`:
  - Example: `10`

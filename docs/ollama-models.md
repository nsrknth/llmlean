# Ollama Models

This document provides a list of models for proving that are available on [Ollama](https://ollama.com/).

## [miniCTX](https://www.arxiv.org/abs/2408.03350)

This is the prover referenced in the main [README](README.md). Again, to use it, you can pull it with the following command:

```bash
ollama pull wellecks/ntpctx-llama3-8b
```

and set 2 configuration variables in `~/.config/llmlean/config.toml`:

```toml
api = "ollama"
model = "wellecks/ntpctx-llama3-8b"
```

## Kimina Models

There are [a few models available from Kimina](https://huggingface.co/collections/AI-MO/kimina-prover-686b72614760ed23038056c5), the collaboration between the Project Numina and Kimi teams.

**Important configuration notes for Kimina models:**
- These models were trained to use Markdown format for inputs and outputs, so you must set `prompt = "markdown"` and `responseFormat = "markdown"`

### `BoltonBailey/Kimina-Prover-Distill-1.7B`

To download the model:

```bash
ollama pull BoltonBailey/Kimina-Prover-Distill-1.7B
```

To use it, set the following configuration variables in `~/.config/llmlean/config.toml`:

```toml
api = "ollama"
model = "BoltonBailey/Kimina-Prover-Distill-1.7B"
prompt = "markdown"
responseFormat = "markdown"
```

### `BoltonBailey/Kimina-Prover-Distill-8B`

To download the model:

```bash
ollama pull BoltonBailey/Kimina-Prover-Distill-8B
```

To use it, set the following configuration variables in `~/.config/llmlean/config.toml`:

```toml
api = "ollama"
model = "BoltonBailey/Kimina-Prover-Distill-8B"
prompt = "markdown"
responseFormat = "markdown"
```

### Performance Tips for Kimina Models

- **Set `numSamples` to a small number**: These models generate detailed reasoning chains, so using fewer samples is recommended for better performance

## BFS Provers

The BFS-Prover series ([BFS-Prover-V2](https://arxiv.org/abs/2509.06493) and [BFS-Prover-V1](https://arxiv.org/abs/2502.03438)) are open-source step-level provers developed by ByteDance Seed team.

### `BFS-Prover-V1-7B`

You can pull the model with command:

```bash
ollama pull zeyu-zheng/BFS-Prover-V1-7B
```
Or pull the quantized `q8_0 version:
```bash
ollama pull zeyu-zheng/BFS-Prover-V1-7B:q8_0
```

and set configuration variables in `~/.config/llmlean/config.toml`:

```toml
api = "ollama"
model = "BFS-Prover"
mode = "parallel"
numSamples = "5"
prompt = "tacticstate"
responseFormat = "tactic"
```

### Tips for BFS-Prover models
- These models were trained to use the current tactic state as input and the preceding tactic as output, so you must set `prompt = "tacticstate"`, `responseFormat = "tactic"` and `mode = "parallel"`.
- You can increase `numSamples` (e.g. 5, 10, …) to sample multiple tactics for each state.
- Currently `llmqed` functions the same as `llmstep ""`.
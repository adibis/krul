# krul

A daemon-first orchestration engine for chip design verification (DV). Krul
receives natural-language or structured commands, routes them to multi-step
pipeline definitions called **gears**, and manages parallel LLM calls and
simulation processes to drive DV tasks to completion.

Krul defines `schema/plugin_schema.json` — the contract that knowledge-graph
indexer plugins must follow. What consumes that data is outside krul's scope.

---

## Prerequisites

| Dependency | Version | Notes |
|---|---|---|
| Zig | 0.14+ | `brew install zig` |
| PostgreSQL | 16+ | `brew install postgresql@16` |
| pgvector | 0.7+ | `brew install pgvector` |
| libpq | (with PG) | headers in `/opt/homebrew/opt/postgresql@16/include` |
| ONNX Runtime | 1.17+ | for the NER indexer plugin only |

The daemon (`kruld`) and CLI (`krul`) have **no ONNX dependency**. Only the
`krul-indexer-codebert` plugin binary needs ONNX Runtime.

---

## Build

```sh
# daemon + CLI only (no ONNX)
zig build

# full build including the NER plugin (requires ONNX Runtime)
zig build \
  -Donnxruntime-include=/opt/homebrew/include/onnxruntime \
  -Donnxruntime-lib=/opt/homebrew/lib

# run C smoke tests (NER layer)
zig build test
```

Build outputs in `zig-out/bin/`:
- `kruld` — the daemon
- `krul` — CLI client
- `krul-indexer-codebert` — built-in NER extractor plugin

Override library search paths if your PostgreSQL lives elsewhere:

```sh
zig build \
  -Dpq-include=/usr/include/postgresql \
  -Dpq-lib=/usr/lib
```

---

## Quick Start

```sh
# 1. Create the database
createdb krul

# 2. Apply the schema
psql krul -f schema/001_init.sql

# 3. Initialise config in your project root
krul init

# 4. Start the daemon
kruld start

# 5. Verify
krul status

# 6. Index your SV/UVM project
krul index --project myproject --root /path/to/testbench

# 7. Query indexed entities
echo '{"method":"query","type":"entities","kind":"UVM_AGENT"}' | nc -U /tmp/krul.sock
```

---

## Configuration (`krul.toml`)

`krul init` writes a template. Key sections:

```toml
[indexer]
plugin    = "krul-indexer-codebert"   # extractor plugin on $PATH
models_dir = ""                           # default: $KRUL_MODELS

[db]
conninfo = "dbname=krul host=localhost"

[daemon]
socket    = "/tmp/krul.sock"
log_level = "info"

[llm]
# endpoint = "https://api.anthropic.com/v1"
# model    = "claude-sonnet-4-6"
# api_key_env = "ANTHROPIC_API_KEY"
# — or any OpenAI-compatible endpoint:
# endpoint = "http://localhost:11434/v1"
# model    = "qwen2.5-coder:32b"
```

---

## CLI Commands

```
kruld start     Daemonize and start listening on /tmp/krul.sock
kruld stop      Send SIGTERM to the running daemon
kruld status    Check daemon health and print task queue stats

krul init       Write krul.toml in the current directory
krul index      Trigger incremental NER index (also called by git hook)
```

---

## IPC Protocol

All communication is newline-delimited JSON over the Unix socket at
`/tmp/krul.sock`. One request per connection; the daemon writes one response
and closes.

```sh
# generic client one-liner
echo '<json>' | nc -U /tmp/krul.sock
```

### Core methods

```jsonc
// Health check
{"method": "ping"}
→ {"result": "pong"}

// Daemon + task queue status
{"method": "status"}
→ {"result": {"state": "running", "tasks": {"total": 3, "pending": 1, "running": 1}}}

// Submit a shell task
{"method": "task.submit", "cmd": "make sim", "kind": "shell"}
→ {"result": {"id": 7, "state": "pending"}}

// List recent tasks (last 20)
{"method": "task.list"}
→ {"result": [{"id": 7, "kind": "shell", "state": "done", "exit_code": 0, ...}]}
```

### Entity queries

Query the local entity store built by indexer plugins. All parameters except
`type` are optional filters.

```jsonc
// List entities by kind or name pattern
{"method": "query", "type": "entities", "kind": "UVM_AGENT"}
{"method": "query", "type": "entities", "name": "axi*"}

// Relation graph hop
{"method": "query", "type": "relations", "from": "axi_agent", "rel": "HAS_DRIVER"}

// Assembled context centered on an entity
{"method": "query", "type": "context", "focus": "dma_agent", "depth": 1}

// UVM agents with no covergroup — coverage gap report
{"method": "query", "type": "no_covergroup"}
{"method": "coverage_gaps"}
```

Add `"project": "myproject"` to scope any query to a named project.

### Gear execution

Run a gear end-to-end. The daemon matches the query to a gear by trigger,
runs each stage (LLM call or shell command), substitutes `{stage_id}` template
tokens between stages, and returns the final synthesized output.

```jsonc
{"method": "gear.run", "query": "close coverage on the AXI agent"}
→ {"result": {"gear": "close_coverage", "output": "..."}}

{"method": "gear.run", "query": "triage the nightly regression"}
→ {"result": {"gear": "triage", "output": "..."}}
```

Lookup only (no execution):

```jsonc
{"method": "gear.find", "q": "close coverage"}
→ {"result": {"name": "close_coverage", "stages": 5, "triggers": 4}}
```

### Kanban board

```jsonc
{"method": "kanban.add",  "params": {"title": "close AXI coverage", "gear": "close_coverage", "priority": 80}}
→ {"task_id": "a1b2c3...", "status": "triage"}

{"method": "kanban.list", "params": {"status": "todo", "limit": 20}}
{"method": "kanban.get",  "params": {"task_id": "a1b2c3..."}}
{"method": "kanban.move", "params": {"task_id": "a1b2c3...", "status": "done"}}
{"method": "kanban.link", "params": {"parent_id": "...", "child_id": "..."}}
```

Kanban task statuses: `triage → todo → ready → running → blocked → review → done | archived`

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  kruld                                           │
│                                                     │
│  Unix socket accept loop (single-threaded)          │
│    └── ipc.zig — method routing                     │
│                                                     │
│  Executor thread (queue.zig)                        │
│    └── runs shell/index/triage tasks                │
│    └── fires hooks on state changes                 │
│                                                     │
│  Entity store queries (db.c → libpq)                │
│    └── entities, relationships indexed by plugins   │
│                                                     │
│  Gear registry (gear_registry.zig)                  │
│    └── loads *.gear files from gears/, ~/.krul/  │
│                                                     │
│  Gear executor (executor.zig)                       │
│    └── stage loop, template fill, LLM + process    │
│    └── called synchronously by gear.run IPC method  │
│                                                     │
│  Plugin registry (plugin_registry.zig)              │
│    └── kanban (in-process, plugins/kanban.zig)      │
│    └── extractor plugins (short-lived subprocesses) │
└─────────────────────────────────────────────────────┘
         │ libpq
┌────────▼────────────────────────────────────────────┐
│  PostgreSQL                                         │
│  entities, relationships, tasks, findings           │
│  kanban_tasks, kanban_task_links, kanban_events     │
│  pgvector (embedding vector(768) on entities)       │
└─────────────────────────────────────────────────────┘
```

### Source layout

```
src/c/
  db.c / db.h          PostgreSQL interface (libpq): entities, tasks,
                       entity store queries, kanban CRUD
  validate.c / .h      NDJSON record validator for plugin output
  infer.c / .h         ONNX Runtime inference (NER model)
  tok.c / .h           BPE tokeniser (matches GraphCodeBERT vocab)
  index.c / .h         Entity extraction pipeline (tok → infer → emit)
  plugin_main.c        krul-indexer-codebert binary entry point

src/zig/
  main.zig             CLI entry point: init / start / stop / status / index
  daemon.zig           Double-fork, pidfile, socket accept loop, startup init
  ipc.zig              IPC method dispatch (all JSON-over-Unix-socket handlers)
  queue.zig            In-memory task queue + executor thread
  query.zig            Entity store query wrappers (db.c → IPC handlers)
  gear.zig             Gear file parser (YAML-like, arena-allocated)
  gear_registry.zig    Gear discovery: KRUL_GEARS, ./gears/, ~/.krul/gears/
  executor.zig         Gear stage runner: template fill, LLM calls, process stages
  plugin_registry.zig  Plugin manifest parser + in-process capability dispatch
  hooks.zig            Fire-and-forget hook registry (64 slots)
  plugins/kanban.zig   Kanban capability plugin (handles kanban.* methods)
  plugin_runner.zig    Extractor plugin subprocess runner
  config.zig           krul.toml parser
  index_cmd.zig        `krul index` subcommand
  setup.zig            `krul init` subcommand
  cli.zig              Shared CLI utilities
  c.zig                C FFI bindings import
```

---

## Database Schema

Applied automatically at daemon startup. Manual application:
`psql krul -f schema/001_init.sql`.

```
entities           NER-extracted SV/UVM entities (kind, name, file, line, confidence,
                   embedding vector(768))
relationships      Directed structural edges between entities (kind, from_id, to_id)
tasks              Daemon task queue (shell / index / triage jobs)
findings           Structured LLM analysis results
krul_projects   Named projects with root paths
kanban_tasks       Kanban board cards (9 statuses, gear_name, gear_run_id)
kanban_task_links  Parent/child dependency edges between cards
kanban_events      Audit trail (status changes, comments, finding links)
```

Entity kinds indexed by the built-in NER model:
`MODULE` `PORT` `PARAMETER` `PACKAGE` `INTERFACE` `COVERGROUP` `ASSERTION`
`UVM_AGENT` `UVM_DRIVER` `UVM_MONITOR` `UVM_SEQUENCER` `UVM_SCOREBOARD`
`UVM_ENV` `UVM_TEST` `UVM_SEQUENCE` `CLASS`

---

## Plugin Contract

Krul publishes `schema/plugin_schema.json` — the NDJSON record format that
all extractor plugins must emit. Each line is either an entity or a relation:

```jsonc
// Entity record
{"kind": "entity", "type": "UVM_AGENT", "name": "axi_agent",
 "file": "tb/axi_agent.sv", "line_start": 12, "line_end": 89,
 "confidence": 0.97}

// Relation record
{"kind": "relation", "type": "HAS_DRIVER",
 "from_kind": "UVM_AGENT", "from_name": "axi_agent",
 "to_kind": "UVM_DRIVER", "to_name": "axi_driver",
 "confidence": 0.90}
```

Krul validates every record from every plugin against this schema before
ingesting it. Any system that consumes the entity/relation tables — whether a
graph database, a vector store, or an analysis tool — works from this contract.

---

## Plugin System

Krul supports two plugin kinds, both declared via a `plugin.yaml` manifest.

### Extractor plugins

Short-lived subprocesses. Read file paths from stdin, write NDJSON records to
stdout conforming to `schema/plugin_schema.json`.

```yaml
name: krul-indexer-codebert
kind: extractor
emits_kinds: [UVM_AGENT, UVM_DRIVER, MODULE, COVERGROUP, ...]
emits_relations: [HAS_DRIVER, HAS_MONITOR, EXTENDS, ...]
executable: krul-indexer-codebert
```

The built-in extractor (`krul-indexer-codebert`) runs a fine-tuned
GraphCodeBERT model (125M parameters, MIT licence) for SV/UVM named-entity
recognition. Model files live in `$KRUL_MODELS` or the path set in
`krul.toml`.

**Model performance** (epoch 5, 6,257-file corpus):
F1 = 0.972 · Precision = 0.969 · Recall = 0.975 · Accuracy = 0.995

### Capability plugins

In-process method handlers registered at startup. The kanban plugin ships
built-in.

```yaml
name: krul-kanban
kind: capability
provides_methods: [kanban.add, kanban.list, kanban.get, kanban.update,
                   kanban.move, kanban.link]
provides_hooks:   [on_task_complete, on_finding]
```

### Plugin discovery

Daemon scans at startup:
1. `$KRUL_BIN/../plugins/<name>/plugin.yaml` (built-in)
2. `~/.krul/plugins/<name>/plugin.yaml` (user)
3. `./.krul/plugins/<name>/plugin.yaml` (project, requires `KRUL_ENABLE_PROJECT_PLUGINS=1`)

### Hook system

Hooks are fire-and-forget notifications fired on daemon events:

| Hook | Fires when |
|---|---|
| `pre_index` | Before plugin_runner starts on a file batch |
| `post_index` | After plugin_runner completes |
| `on_task_complete` | A task queue entry reaches `done` or `failed` |
| `on_finding` | A triage gear writes a finding |
| `on_gear_stage_complete` | A gear executor stage finishes |
| `on_gear_complete` | A gear run reaches its termination condition |

---

## Gears (Pipeline Definitions)

Gears are YAML-like pipeline definitions that describe multi-step DV tasks.
The daemon loads them at startup from (in priority order):

1. `KRUL_GEARS` env var directory
2. `./gears/` alongside the binary
3. `~/.krul/gears/`

### Format

```yaml
name: close_coverage
version: 2

triggers:
  - "close coverage"
  - "coverage closure"

stages:
  - id: decompose
    type: llm
    prompt: "Identify which functional scenarios will close remaining coverage holes.\n\nTask: {input}\nKnown entities:\n{context}"
  - id: execute
    type: process
    prompt: "echo 'Coverage plan: {decompose}' && date"
  - id: analyze
    type: llm
    prompt: "Analyze the simulation output and identify remaining gaps.\n\nPlan:\n{decompose}\n\nOutput:\n{execute}"
  - id: synthesize
    type: llm
    prompt: "Synthesize into a prioritized action list.\n\nAnalysis:\n{analyze}"

termination:
  condition: synthesize.status == done
  max_iterations: 3
  on_max: return_last_synthesize
```

**Template tokens**: `{input}` = original user query, `{context}` = entity-store
context injected by the executor, `{stage_id}` = output from a prior stage.
`\n` in prompt strings is unescaped to a real newline at runtime.

Stage types: `llm` `process` `parallel_llm` `condition`

### Built-in gears

| Gear | Triggers | Description |
|---|---|---|
| `close_coverage` | "close coverage", "coverage closure" | Decompose → simulate → analyze gaps (parallel) → synthesize |
| `triage` | "triage", "failures", "regression triage" | Parse failure logs → cluster → root-cause per cluster → synthesize |
| `simulate` | "simulate", "run sim", "smoke test" | Build run command → launch subprocess → parse pass/fail |
| `debug` | "debug", "why is", "investigate" | Gather context → 3 hypotheses → verify each → rank |

---

## Planned Phases

| Phase | Goal | Status |
|---|---|---|
| 1 — Entity store queries | IPC query handlers against indexed entity/relation tables | ✓ Done |
| 2 — Gear format + parser | Load and validate gear definition files | ✓ Done |
| 2B — Plugin infrastructure | Plugin manifests, hooks, kanban plugin | ✓ Done |
| 3 — LLM pool | Parallel structured LLM calls (Anthropic + OpenAI-compat) | ✓ Done |
| 4 — Gear executor | Run a gear end-to-end: stage loop, template fill, iteration | ✓ Done |
| 5 — Router | Natural language → gear selection (trigger match → embedding → LLM) | Next |
| 6 — Relation extraction | Heuristic SV relation extractor (EXTENDS, HAS_DRIVER, DRIVES…) | |
| 7 — pgvector embeddings | Semantic entity search via HNSW index | |
| 8 — TUI | Interactive REPL + live task queue + findings panes | |
| 9 — Hardening | `kruld doctor`, config validation, structured errors | |

### Phase 3 — LLM Pool ✓

`src/zig/llm.zig` — two backends: Anthropic (native `tool_use` for structured
output) and OpenAI-compatible (`json_schema` mode). Synchronous single calls via
`llm.call()` and parallel fan-out via `llm.callParallel()` (thread-per-request).
Backend auto-detected from endpoint URL; API key resolved from env at init time.

### Phase 4 — Gear Executor ✓

`src/zig/executor.zig` — the stage runner called by `gear.run`. Loops through
each stage in order; for `llm`/`parallel_llm` stages calls `llm.call()` with the
template-filled prompt; for `process` stages runs the command via `krl_exec_shell`.
Template engine substitutes `{input}`, `{context}`, and `{stage_id}` tokens using
prior stage outputs. Respects `termination.condition` and `max_iterations`. All
four built-in gear files carry concrete prompt templates.

### Phase 5 — Router (next)

`src/zig/router.zig` — three-tier query classification:

1. **Structural match** — pure entity-store queries (`"list all UVM agents"`,
   `"which modules have no covergroup"`) bypass gears entirely and go directly
   to the `query` IPC handler.
2. **Trigger match** — substring match against gear trigger lists. Already
   implemented in `gear_registry.zig`; the router formalizes it as a first-pass.
3. **Embedding similarity** — encode the query with the encoder model; cosine
   similarity against cached gear trigger embeddings. Fallback when trigger
   match misses.
4. **LLM fallback** — for ambiguous or novel queries, a lightweight LLM call
   with the gear list selects the best match or returns `null` for direct
   entity-store dispatch.

Done when a router test suite correctly routes 20 labelled queries across all
four gear types plus the structural bypass case, with no LLM calls for
trigger-matched or structural inputs.

---

## Development Notes

**Single-threaded IPC loop**: `ipc.zig` uses module-level `g_resp_buf` and
`g_data_buf` instead of stack buffers. Returning slices into stack-allocated
arrays from `dispatch()` is UB; the module-level buffers are safe because the
accept loop handles one connection at a time.

**Gear parser**: line-oriented indent state machine in `gear.zig`. Indent 0 =
top-level scalars/section headers; indent 2 = list items; indent 4 = object
fields within list items. All strings are arena-allocated; call `gear.deinit()`
to free.

**Optional SQL filters**: nullable query parameters use PostgreSQL's
`$N::text IS NULL OR col = $N` pattern. When libpq passes a C NULL pointer for
a params-array entry, `$N` becomes SQL NULL, the `IS NULL` branch is TRUE, and
the filter is skipped entirely.

**In-process capability plugins**: `plugins/kanban.zig` is linked directly into
the daemon rather than running as a sidecar process. The external-process
protocol (Unix socket NDJSON with `{"ready":true,"socket":"..."}` handshake)
is planned for Phase 9 (Hardening).

---

## Licence

Source available. See LICENCE file.

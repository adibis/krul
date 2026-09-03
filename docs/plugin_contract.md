# Krul Plugin Contract

Krul is a daemon orchestrator. It does not own a knowledge-graph extractor. Instead it defines a contract that any extractor must satisfy. The daemon spawns the extractor, feeds it files, validates its output, and inserts the results into PostgreSQL. The extractor only needs to understand source code and emit structured records.

---

## Subprocess Protocol

The daemon forks the plugin executable and communicates over stdio.

| Stream | Direction | Content |
|--------|-----------|---------|
| `stdin`  | daemon → plugin | Absolute file paths, one per line; EOF when all paths have been sent |
| `stdout` | plugin → daemon | Newline-delimited JSON records (NDJSON); one entity or relation per line |
| `stderr` | plugin → daemon | Diagnostics only — forwarded to daemon stderr, never parsed |

The daemon discovers source files (`*.sv`, `*.v`, `*.svh`, `*.uvm`) under standard subdirectories (`rtl/`, `tb/`, `dv/`, `uvm/`, `.`) of the project root, deletes any previously-indexed entities for those files, then spawns the plugin and streams the paths. The plugin may emit records for any of the files it receives, in any order. Lines beginning with `#` are silently ignored (use them for progress comments if needed).

When the plugin exits the daemon reaps it. A non-zero exit code produces a warning log but does not fail the index run — records already ingested are kept.

---

## Record Formats

Every line on stdout must be a valid JSON object. The schema is at `schema/plugin_schema.json`. The daemon validates each line before insertion; invalid lines are counted as errors and skipped.

### Entity Record

```json
{
  "type": "entity",
  "partition": "verification",
  "kind": "UVM_AGENT",
  "name": "aes_agent",
  "file": "/home/user/opentitan/hw/ip/aes/dv/env/aes_agent.sv",
  "line_start": 14,
  "line_end": 42,
  "confidence": 0.97,
  "confidence_source": "ml_predicted",
  "properties": {
    "isActive": "active",
    "className": "aes_agent"
  }
}
```

**Required fields** (validation fails without any of these):

| Field | Type | Notes |
|-------|------|-------|
| `type` | string | Must be `"entity"` |
| `partition` | string | Must match the kind — see table below |
| `kind` | string | One of the 32 recognised entity kinds |
| `name` | string | Non-empty |
| `file` | string | **Absolute path** — must start with `/` |
| `line_start` | integer | ≥ 1 |
| `confidence` | number | In [0.0, 1.0] |

**Optional fields:**

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `line_end` | integer | — | Last line of the entity |
| `confidence_source` | string | `"ml_predicted"` | One of: `ml_predicted`, `static_parsed`, `heuristic`, `explicit` |
| `properties` | object | — | Kind-specific optional properties (port direction, width, access policy, etc.) |

### Relation Record

```json
{
  "type": "relation",
  "kind": "DRIVES",
  "from_kind": "UVM_DRIVER",
  "from_name": "aes_driver",
  "to_kind": "INTERFACE",
  "to_name": "aes_if",
  "confidence": 0.85,
  "confidence_source": "heuristic"
}
```

**Required fields:**

| Field | Type | Notes |
|-------|------|-------|
| `type` | string | Must be `"relation"` |
| `kind` | string | One of the 46 recognised relation kinds |
| `from_kind` | string | Must be a recognised entity kind |
| `from_name` | string | Non-empty |
| `to_kind` | string | Must be a recognised entity kind |
| `to_name` | string | Non-empty |
| `confidence` | number | In [0.0, 1.0] |

**Optional fields:**

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `confidence_source` | string | `"heuristic"` | Same enum as entity |
| `properties` | object | — | e.g. `viaModport`, `paramBindings`, `bindTarget` |

---

## Partition / Kind Table

`partition` is not inferred — it must be specified correctly or the record is rejected (validation rule IC-1).

| Partition | Entity Kinds |
|-----------|-------------|
| `structural` | `MODULE`, `INTERFACE`, `PORT`, `MODPORT`, `PARAMETER`, `PACKAGE`, `CLOCK_DOMAIN`, `CLOCKING_BLOCK` |
| `verification` | `UVM_TEST`, `UVM_ENV`, `UVM_AGENT`, `UVM_DRIVER`, `UVM_MONITOR`, `UVM_SCOREBOARD`, `UVM_SEQUENCER`, `UVM_SEQUENCE`, `UVM_SEQ_ITEM`, `CONSTRAINT_BLOCK`, `RAND_VAR`, `CONFIG_DB_ENTRY`, `FACTORY_OVERRIDE` |
| `coverage` | `COVERGROUP`, `COVERPOINT`, `ASSERTION`, `CHECKER`, `SVA_PROPERTY`, `SVA_SEQUENCE` |
| `register` | `REG_MAP`, `REG_BLOCK`, `REGISTER`, `REG_FIELD` |

---

## Entity Kinds (complete list)

`MODULE` `INTERFACE` `PORT` `MODPORT` `PARAMETER` `PACKAGE` `CLOCK_DOMAIN` `CLOCKING_BLOCK` `UVM_TEST` `UVM_ENV` `UVM_AGENT` `UVM_DRIVER` `UVM_MONITOR` `UVM_SCOREBOARD` `UVM_SEQUENCER` `UVM_SEQUENCE` `UVM_SEQ_ITEM` `CONSTRAINT_BLOCK` `RAND_VAR` `CONFIG_DB_ENTRY` `FACTORY_OVERRIDE` `COVERGROUP` `COVERPOINT` `ASSERTION` `CHECKER` `SVA_PROPERTY` `SVA_SEQUENCE` `REG_MAP` `REG_BLOCK` `REGISTER` `REG_FIELD`

## Relation Kinds (complete list)

`INSTANTIATES` `HAS_PORT` `HAS_MODPORT` `HAS_PARAMETER` `USES_PACKAGE` `HAS_CLOCKING_BLOCK` `DECLARED_IN` `IN_CLOCK_DOMAIN` `BRIDGES_FROM_DOMAIN` `BRIDGES_TO_DOMAIN` `CONTAINS` `INSTANTIATES_ENV` `PULLS_FROM` `PUBLISHES_TO` `HAS_VIRTUAL_IF` `HAS_CONSTRAINT` `HAS_RAND_VAR` `DECLARES_OVERRIDE` `SETS_CONFIG` `GETS_CONFIG` `GENERATES` `RUNS_ON` `EXTENDS` `PART_OF` `CROSSES_WITH` `DRIVES` `MONITORS` `CALLS_BFM` `TESTS` `CHECKS` `COVERS` `REFERENCES` `BOUND_TO` `STIMULATES` `ABSTRACTS` `MAPS_TO` `REFERENCES_PROPERTY` `REFERENCES_SEQUENCE` `MAPS_REGISTER` `SAMPLES` `INSTANTIATES_CG` `OVERRIDES_CONSTRAINT` `DISABLES_CONSTRAINT` `RANDOMIZES` `STARTS` `GETS_RESPONSE`

---

## Plugin Manifest (plugin.yaml)

The daemon discovers plugins by scanning three directories in order:

1. Paths in the `KRUL_PLUGINS` environment variable (colon-separated)
2. `./plugins/` relative to the working directory
3. `~/.krul/plugins/`

Each plugin lives in its own subdirectory with a `plugin.yaml` manifest:

```yaml
name: shadowthrone
version: 1.0.0
description: Static AST parser for SV/UVM entities
kind: extractor
executable: shadowthrone        # binary name (must be on PATH) or absolute path
emits_kinds:
  - MODULE
  - INTERFACE
  - UVM_AGENT
  - UVM_DRIVER
emits_relations:
  - INSTANTIATES
  - DRIVES
  - EXTENDS
```

The `emits_kinds` and `emits_relations` lists are informational — the daemon does not filter records based on them, but they allow tooling to reason about plugin capabilities without running it.

To activate a specific plugin, set it in `krul.toml`:

```toml
[indexer]
plugin = "shadowthrone"
```

If `plugin` is unset the daemon falls back to whichever plugin appears first in the scan order.

---

## What the Plugin Does NOT Need to Implement

- **Database access** — the daemon owns the DB connection; the plugin never talks to PostgreSQL.
- **File discovery** — the daemon walks the project tree and sends paths over stdin.
- **Deduplication** — the daemon deletes stale entities for each file before spawning the plugin.
- **Stale cleanup** — handled automatically; the plugin only emits what it found.
- **IPC / socket communication** — the plugin is a simple subprocess, not a server.
- **Confidence thresholding** — emit the confidence value you have; the daemon logs a warning for values below 0.5 but still ingests the record.
- **Ontology versioning** — the daemon enforces the schema; the plugin just needs to conform to it.

---

## KB Update Contract (Git Hook)

When source files change the daemon should be notified so it can schedule a re-index. Any tool (git hook, CI pipeline, IDE plugin) can do this by sending a JSON message to the daemon's Unix socket at `/tmp/krul.sock` (configurable via `KRUL_SOCK`).

The message schema is at `schema/index_contract.json`:

```json
{ "method": "index", "project": "opentitan", "files": ["hw/ip/aes/rtl/aes.sv"] }
```

| Field | Required | Notes |
|-------|----------|-------|
| `method` | yes | Must be `"index"` |
| `project` | no | Project name as registered with the daemon; defaults to `"default"` |
| `files` | no | Changed file paths relative to project root; omit for a full re-index |

A template post-commit hook that sends this message is provided at `hooks/post-commit`. Install it:

```sh
cp hooks/post-commit .git/hooks/post-commit
chmod +x .git/hooks/post-commit
```

The hook silently skips if the daemon socket is not present, so it is safe to install even when the daemon is not running.

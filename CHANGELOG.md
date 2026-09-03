# krul Changelog

All notable changes will be documented here.
Format: [version/date] — what changed and why.

---

## [0.5.0] — 2026-05-31

### Phases 3 + 4: LLM Pool and Gear Executor

**Phase 3 — LLM pool** (`src/zig/llm.zig`):
- Two backends: Anthropic (native `tool_use`) and OpenAI-compatible (`json_schema`)
- `llm.call()` — synchronous HTTPS call; returns content, token counts, latency
- `llm.callParallel()` — fan-out to N threads, results indexed by request
- `llm.call` exposed via IPC: `{"method": "llm.call", "user": "...", "system": "..."}`

**Phase 4 — Gear executor** (`src/zig/executor.zig`):
- `executor.run(ally, gear, input, context)` — runs all stages in sequence
- Template engine: `{input}`, `{context}`, `{stage_id}` substituted at runtime
- `llm`/`parallel_llm` stages call LLM pool; `process` stages run via shell
- Termination condition checked after each pass; `max_iterations` enforced
- `gear.run` IPC method: match query → gear by trigger, run executor, return output

**Gear files** (all four updated to version 2 with concrete prompt templates):
- `close_coverage`: decompose → execute (shell) → analyze → analyze_gaps → synthesize
- `triage`: locate (grep sim.log) → cluster → analyze_clusters → synthesize
- `simulate`: decompose (LLM → shell cmd) → execute → analyze
- `debug`: decompose → hypothesize → verify → synthesize

**Gear format extended**:
- `Stage.prompt: []const u8` field (default `""`); parsed at indent-4

---

## [0.3.0] — 2026-05-11

### Gear 01 Complete — Fine-Tuned SV/UVM NER Model

**Model**: GraphCodeBERT (125M, MIT) fine-tuned for SV/UVM NER + embeddings
**Output**: `azath_sv_v1.onnx` (pending ONNX export, Step 9)
**Hardware**: M4 Pro 24GB, ~18 min training on MPS

**Corpus** (6,257 files, 1.27M lines, 11 repos, all Apache 2.0/MIT):
- OpenTitan, Ibex, CVA6, AXI, common_cells, VeeR-EH1/EH2, uvm-core,
  core-v-verif, caliptra-rtl, cv32e40p, uvmBasics

**Results** (epoch 5, expanded corpus):
- Overall F1: 0.972, Precision: 0.969, Recall: 0.975, Accuracy: 0.995
- Per-entity: MODULE 0.985, PORT 0.980, PARAMETER 0.970, COVERGROUP 1.000, PACKAGE 0.978
- UVM types: F1 ≈ 0.000 — known gap; root cause: class imbalance + indirect inheritance
- Embeddings: dma_ctrl ↔ dma_engine = 0.970, dma_ctrl ↔ axi_driver = 0.739 ✓

**Tooling lessons**:
- Verible requires `--printtree --export_json` together (not `--export_json` alone)
- SV files contain large comment blocks — `blank_comments()` required before tokenizing
- Generated files (register banks, RDL outputs) must be filtered; `is_generated()` checks first 1KB for "do not edit" markers

**Architecture decision — Hierarchical embeddings** (added to ARCHITECTURE.md):
Each entity node carries 4 embedding properties instead of 1:
- `structural_embedding float[768]` — GraphCodeBERT on declaration + ports (current model)
- `behavioral_embedding float[768]` — GraphCodeBERT mean-pooled over full entity body
- `summary_embedding float[768]` — MiniLM on LLM-generated behavioral description
- `summary_text string` — human-readable behavioral description (shown at query time)
Rationale: name/port similarity alone cannot find two frame-processing sequences with
different names; behavioral and summary tracks capture protocol-level intent.

**Architecture decision — Behavioral embedding pipeline** (Gear 02b, to be built):
Local Qwen2.5-Coder-7B generates `summary_text` per entity body at index time.
`all-MiniLM-L6-v2` embeds it to `summary_embedding`. No API calls.

**Architecture decision — Structured protocol tags on KB nodes**:
Bug/Erratum/FailureSignature nodes get explicit tags: `{protocol, error_type, direction}`
for exact matching queries that embeddings cannot handle reliably.

**Known gaps for v2 model** (Phase 6):
- UVM indirect inheritance: `class A extends B` where `B extends uvm_driver` — A not labeled
- CLOCK_DOMAIN F1=0.000 in test (only 5 examples); needs regex improvement
- Class imbalance: PORT 3,091 test examples vs UVM_AGENT 2

---

## [0.2.1] — 2026-05-05

### Changed (ARCHITECTURE.md + PLAN.md — v2.1)
- Kuzu dropped: acquired by Apple Oct 2025, GitHub repo archived, not viable
- Replaced with Apache AGE (graph, openCypher) + pgvector (embeddings) as PostgreSQL extensions
- Architecture now: 1 service total (PostgreSQL). Down from 4 (v1.0) → 2 (v2.0) → 1 (v2.1)
- azathd connects via libpq (C); no embedded graph library needed
- pgvector `<=>` operator replaces Kuzu float[] cosine scan

---

## [0.2.0] — 2026-05-05

### Changed (ARCHITECTURE.md + PLAN.md — v2.0)
- Storage: Neo4j + Qdrant + Redis → Kuzu (embedded) + PostgreSQL only (2 services total)
- SV parser: tree-sitter → Slang (full LRM, elaboration, resolved params)
- Firmware parser: tree-sitter-c → libclang (preprocessor evaluation, macro resolution)
- Added libazath_rdl.so: SystemRDL/IP-XACT as authoritative CSR source
- Added libazath_model.so: fine-tuned GraphCodeBERT/DeepSeek-Coder for entity extraction + embeddings
- Embeddings stored as float[] on Kuzu nodes; replaces Qdrant entirely
- Primary trigger: git hooks (replaces inotify — NFS-safe for EDA environments)
- Consistency Checker is now a separate nightly job; not part of index pipeline
- Edge provenance on all edges: source_commit, source_doc_hash, staleness_flag
- New node types (14): ChipRevision, Erratum, Bug, FailureSignature, RootCause, Workaround,
  ClockDomain, ResetDomain, BootStage, PowerState, ISR, InterfaceContract, DesignNote, ToolEnvironment
- Spec nodes: versioned, never tombstoned; superseded → SUPERSEDED_BY edge
- UVM CONTAINS edges: marked confidence: static_inferred
- CoverGroup: added coverage closure properties
- CSR_CONFLICT edges emitted when RDL/header/spec disagree on same register
- Plan: 28 weeks → 34 weeks; new Phase 6 (bug KB + coverage + model iteration)

### Added
- CRITIQUE.md: synthesis of RTL, DV, Architecture, Firmware expert reviews (2026-04-30)

---

## [0.1.0] — 2026-04-30

### Added
- PROMPT.md: full project vision, scale requirements, technology rationale
- ARCHITECTURE.md: system diagram, graph schema (node/edge types), multi-tenancy model, update pipeline, JSON-RPC API contract
- PLAN.md: 6-phase implementation plan (~28 weeks to production)

### Research basis
- HippoRAG 2 (ICML 2025): entity-centric indexing + PPR traversal
- PathRAG (2025): relational path pruning, 44% token reduction
- LightRAG (EMNLP 2025): incremental graph updates without rebuild
- GraphRAG (Microsoft): hierarchical community summaries → adapted to IP/project summary nodes
- EcphoryRAG (2025): 94% token reduction via engram-style entity extraction
- NeuroPath (2025): semantic path coherence improvements
- Storage: Neo4j selected for IP-level database isolation + ACID + proven multi-tenancy

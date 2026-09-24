#!/usr/bin/env python3
"""
HV-Onto static extractor — regex-based SV/UVM entity and relation extractor.
Emits newline-delimited JSON conforming to schema/plugin_schema.json.

Usage:
    python3 extractor.py <root_dir> [<root_dir>...]

Each argument is recursively scanned for *.sv files.
"""

import re, sys, os, json
from pathlib import Path

# ── Partition / kind table ────────────────────────────────────────────────────

PARTITION = {
    'MODULE': 'structural', 'INTERFACE': 'structural', 'PORT': 'structural',
    'MODPORT': 'structural', 'PARAMETER': 'structural', 'PACKAGE': 'structural',
    'CLOCK_DOMAIN': 'structural', 'CLOCKING_BLOCK': 'structural',
    'UVM_TEST': 'verification', 'UVM_ENV': 'verification',
    'UVM_AGENT': 'verification', 'UVM_DRIVER': 'verification',
    'UVM_MONITOR': 'verification', 'UVM_SCOREBOARD': 'verification',
    'UVM_SEQUENCER': 'verification', 'UVM_SEQUENCE': 'verification',
    'UVM_SEQ_ITEM': 'verification', 'CONSTRAINT_BLOCK': 'verification',
    'RAND_VAR': 'verification', 'CONFIG_DB_ENTRY': 'verification',
    'FACTORY_OVERRIDE': 'verification',
    'UVM_EVENT': 'verification',
    'COVERGROUP': 'coverage', 'COVERPOINT': 'coverage', 'ASSERTION': 'coverage',
    'CHECKER': 'coverage', 'SVA_PROPERTY': 'coverage', 'SVA_SEQUENCE': 'coverage',
    'REG_MAP': 'register', 'REG_BLOCK': 'register',
    'REGISTER': 'register', 'REG_FIELD': 'register',
}

# Base-class → kind mapping (direct match only; transitivity resolved in pass 2).
# Includes both canonical UVM base classes and Moore.io UVMx framework wrappers
# (uvmx_*_c) used by enterprise testbenches such as core-v-mcu-uvm.
UVM_BASE_KIND = {
    # ── Canonical UVM ────────────────────────────────────────────────────────
    'uvm_test':            'UVM_TEST',
    'uvm_env':             'UVM_ENV',
    'cip_base_env':        'UVM_ENV',
    'dv_base_env':         'UVM_ENV',
    'uvm_agent':           'UVM_AGENT',
    'dv_base_agent':       'UVM_AGENT',
    'uvm_driver':          'UVM_DRIVER',
    'tl_base_driver':      'UVM_DRIVER',
    'dv_base_driver':      'UVM_DRIVER',
    'uvm_reg_adapter':     'UVM_DRIVER',
    'uvm_monitor':         'UVM_MONITOR',
    'dv_base_monitor':     'UVM_MONITOR',
    'uvm_scoreboard':      'UVM_SCOREBOARD',
    'dv_base_scoreboard':  'UVM_SCOREBOARD',
    'cip_base_scoreboard': 'UVM_SCOREBOARD',
    'uvm_sequencer':       'UVM_SEQUENCER',
    'uvm_sequence':        'UVM_SEQUENCE',
    'cip_base_vseq':       'UVM_SEQUENCE',
    'dv_base_vseq':        'UVM_SEQUENCE',
    'uvm_reg_sequence':    'UVM_SEQUENCE',
    'uvm_sequence_item':   'UVM_SEQ_ITEM',
    'uvm_object':          None,   # too generic
    'uvm_component':       None,   # too generic
    'uvm_reg_block':       'REG_BLOCK',
    'uvm_reg':             'REGISTER',
    'uvm_reg_field':       'REG_FIELD',
    'uvm_reg_map':         'REG_MAP',
    # ── Moore.io UVMx framework (wraps standard UVM) ─────────────────────────
    'uvmx_env_c':          'UVM_ENV',
    'uvmx_ss_env_c':       'UVM_ENV',
    'uvmx_chip_env_c':     'UVM_ENV',
    'uvmx_agent_env_c':    'UVM_ENV',
    'uvmx_b_env_c':        'UVM_ENV',
    'uvmx_test_c':         'UVM_TEST',
    'uvmx_chip_test_c':    'UVM_TEST',
    'uvmx_ss_test_c':      'UVM_TEST',
    'uvmx_b_test_c':       'UVM_TEST',
    'uvmx_agent_c':        'UVM_AGENT',
    'uvmx_drv_c':          'UVM_DRIVER',
    'uvmx_mp_drv_c':       'UVM_DRIVER',
    'uvmx_mon_c':          'UVM_MONITOR',
    'uvmx_mp_mon_c':       'UVM_MONITOR',
    'uvmx_sqr_c':          'UVM_SEQUENCER',
    'uvmx_agent_sqr_c':    'UVM_SEQUENCER',
    'uvmx_seq_c':          'UVM_SEQUENCE',
    'uvmx_agent_seq_c':    'UVM_SEQUENCE',
    'uvmx_seq_lib_c':      'UVM_SEQUENCE',
    'uvmx_seq_item_c':     'UVM_SEQ_ITEM',
    'uvmx_mon_trn_c':      'UVM_SEQ_ITEM',
    'uvmx_sb_c':           'UVM_SCOREBOARD',
    'uvmx_reg_block_c':    'REG_BLOCK',
    'uvmx_reg_c':          'REGISTER',
    'uvmx_reg_field_c':    'REG_FIELD',
}

# ── Regex patterns ────────────────────────────────────────────────────────────

RE_MODULE    = re.compile(r'^\s*module\s+(\w+)\b', re.MULTILINE)
RE_IFACE     = re.compile(r'^\s*interface\s+(\w+)\b', re.MULTILINE)
RE_PACKAGE   = re.compile(r'^\s*package\s+(\w+)\b', re.MULTILINE)
RE_CLASS     = re.compile(
    r'^\s*(?:virtual\s+)?class\s+(\w+)\s*(?:#\s*\([^)]*\)\s*)?extends\s+(\w[\w:]*)',
    re.MULTILINE)
RE_COVERGRP  = re.compile(r'^\s*covergroup\s+(\w+)\b', re.MULTILINE)
RE_COVERPNT  = re.compile(r'^\s+(\w+)\s*:\s*coverpoint\b', re.MULTILINE)
RE_PROPERTY  = re.compile(r'^\s*property\s+(\w+)\b', re.MULTILINE)
RE_SEQUENCE  = re.compile(r'^\s*sequence\s+(\w+)\b', re.MULTILINE)
RE_ASSERT    = re.compile(r'^\s*(\w+)\s*:\s*assert\s+property\s*\(', re.MULTILINE)
RE_BIND      = re.compile(
    r'^\s*bind\s+(\w+)\s+(\w+)\s+(\w+)\s*\(', re.MULTILINE)
RE_INSTMOD   = re.compile(
    r'^\s*(\w+)\s+(?:#\s*\([^)]*\)\s*)?(\w+)\s*\(\s*(?:\.\w+\s*\()?', re.MULTILINE)
RE_EXTENDS   = re.compile(
    r'^\s*(?:virtual\s+)?class\s+(\w+)\s*(?:#[^;]+)?\s*extends\s+(\w[\w:]*)',
    re.MULTILINE)
RE_SAMPLE    = re.compile(r'\b(\w+)\.sample\s*\(', re.MULTILINE)
RE_START     = re.compile(r'\b(\w+)\.start\s*\(\s*(\w+)', re.MULTILINE)
RE_CLKBLK    = re.compile(r'^\s*clocking\s+(\w+)\b', re.MULTILINE)
RE_RANDVAR   = re.compile(r'^\s*rand(?:c)?\s+\w[\w\s\[\]]*\s+(\w+)\s*;', re.MULTILINE)
RE_CONSTRAINT= re.compile(r'^\s*(?:extern\s+)?constraint\s+(\w+)\b', re.MULTILINE)
RE_DRIVES    = re.compile(
    r'virtual\s+(\w+)\s+\w+\s*[;=]', re.MULTILINE)
RE_PKG_IMPORT= re.compile(r'\bimport\s+(\w+)::', re.MULTILINE)
RE_PKG_USE   = re.compile(r'\b(\w+_pkg)::', re.MULTILINE)

# ── Gap 3-6 patterns ──────────────────────────────────────────────────────────

RE_UVM_DO       = re.compile(r'`uvm_do(?:_with)?\s*\(\s*(\w+)', re.MULTILINE)
RE_P_SEQ        = re.compile(r'`uvm_declare_p_sequencer\s*\(\s*(\w+)\s*\)', re.MULTILINE)
RE_CREATE       = re.compile(r'\b(\w+)::type_id::create\s*\(\s*"([^"]*)"', re.MULTILINE)
RE_RUN_PHASE    = re.compile(r'^\s*(?:virtual\s+)?task\s+run_phase\s*\(', re.MULTILINE)
RE_ENDCLASS     = re.compile(r'\bendclass\b', re.MULTILINE)
RE_UVM_EVT_GL   = re.compile(r'uvm_event_pool::get_global\s*\(\s*"(\w+)"', re.MULTILINE)
RE_UVM_EVT_DECL = re.compile(r'^\s*uvm_event\s+(\w+)\s*;', re.MULTILINE)
RE_TRIGGER      = re.compile(r'\b(\w+)\.trigger\s*\(\s*\)', re.MULTILINE)
RE_WAIT_TRIG    = re.compile(r'\b(\w+)\.wait_trigger(?:_data)?\s*\(', re.MULTILINE)
RE_RAND_TYPED   = re.compile(r'^\s*rand(?:c)?\s+(\w[\w:]*)\s+(\w+)\s*(?:\[.*?\])?\s*;', re.MULTILINE)
RE_FUNC_TASK    = re.compile(
    r'^\s*(?:virtual\s+)?(?:function|task)\s+(?:void\s+|automatic\s+)?(?:\w+\s+)?(\w+)\s*\(',
    re.MULTILINE)

# Keywords that look like module names but aren't instantiations
SV_KEYWORDS = frozenset([
    'begin','end','if','else','case','casez','casex','endcase','for','foreach',
    'while','do','repeat','forever','fork','join','join_any','join_none',
    'always','always_ff','always_comb','always_latch','initial','final',
    'generate','endgenerate','function','endfunction','task','endtask',
    'module','endmodule','interface','endinterface','class','endclass',
    'package','endpackage','program','endprogram','checker','endchecker',
    'clocking','endclocking','property','endproperty','sequence','endsequence',
    'virtual','static','automatic','local','protected','pure','extern',
    'rand','randc','constraint','covergroup','endgroup','coverpoint','bins',
    'assign','wire','logic','reg','bit','int','integer','byte','shortint',
    'longint','real','realtime','time','string','void','enum','struct',
    'union','typedef','localparam','parameter','defparam','input','output',
    'inout','ref','supply0','supply1','tri','triand','trior','uwire',
    'assert','assume','cover','restrict','disable','iff','unique','priority',
    'inside','dist','with','solve','before','bind','import','export',
    'new','this','super','null','default','type','return','break','continue',
    'tagged','matches','packed','unpacked','signed','unsigned','const',
    'interconnect','nettype','let','interconnect','global','first_match',
    'accept_on','reject_on','sync_accept_on','sync_reject_on',
    'wait_order','randcase','randsequence',
    # common preprocessor
    'include','define','ifdef','ifndef','elsif','else','endif','undef',
    # common UVM macros
    'uvm_component_utils','uvm_object_utils','uvm_field_int','uvm_info',
    'uvm_error','uvm_fatal','uvm_warning','uvm_blocking_get_port',
    'downcast','DV_CHECK_RANDOMIZE_FATAL','gmv','gfn',
])

# ── Helpers ───────────────────────────────────────────────────────────────────

def lineno(text, pos):
    return text[:pos].count('\n') + 1

def strip_comments(src):
    """Remove // and /* */ comments while preserving line count."""
    # block comments
    src = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group().count('\n'), src, flags=re.DOTALL)
    # line comments
    src = re.sub(r'//[^\n]*', '', src)
    return src

def emit(record):
    print(json.dumps(record, separators=(',', ':')))

def entity(kind, name, file, line, conf=0.92, src='static_parsed', props=None):
    r = {
        'type': 'entity',
        'partition': PARTITION[kind],
        'kind': kind,
        'name': name,
        'file': str(file),
        'line_start': line,
        'confidence': conf,
        'confidence_source': src,
    }
    if props:
        r['properties'] = props
    return r

def relation(kind, fk, fn, tk, tn, conf=0.85, src='heuristic'):
    return {
        'type': 'relation',
        'kind': kind,
        'from_kind': fk,
        'from_name': fn,
        'to_kind': tk,
        'to_name': tn,
        'confidence': conf,
        'confidence_source': src,
    }

def find_containing_class(src, pos, class_kind_map):
    """Return (class_name, class_kind) for the class declaration last seen before pos."""
    best_name, best_kind, best_start = None, None, -1
    for m in RE_CLASS.finditer(src):
        if m.start() < pos and m.start() > best_start:
            name = m.group(1)
            kind = class_kind_map.get(name)
            if kind:
                best_start = m.start()
                best_name  = name
                best_kind  = kind
    return best_name, best_kind

def find_containing_task(src, pos):
    """Return the name of the function/task whose declaration most immediately precedes pos."""
    best_name, best_start = None, -1
    for m in RE_FUNC_TASK.finditer(src):
        if m.start() < pos and m.start() > best_start:
            best_start = m.start()
            best_name  = m.group(1)
    return best_name

# ── Per-file extraction ───────────────────────────────────────────────────────

def extract_file(path, class_kind_map):
    """
    Returns (entities, relations) lists.
    class_kind_map is updated in-place with new class→kind mappings found.
    """
    entities = []
    relations = []
    abspath = os.path.abspath(path)

    try:
        raw = Path(path).read_text(errors='replace')
    except Exception:
        return entities, relations

    src = strip_comments(raw)
    fname = os.path.basename(path)

    # ── Structural ────────────────────────────────────────────────────────────

    for m in RE_MODULE.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('MODULE', name, abspath, lineno(src, m.start())))

    for m in RE_IFACE.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('INTERFACE', name, abspath, lineno(src, m.start())))

    for m in RE_PACKAGE.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('PACKAGE', name, abspath, lineno(src, m.start())))

    for m in RE_CLKBLK.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('CLOCKING_BLOCK', name, abspath, lineno(src, m.start())))

    # ── UVM/Verification classes ───────────────────────────────────────────────

    for m in RE_CLASS.finditer(src):
        cls_name  = m.group(1)
        base_name = m.group(2).split('::')[-1]   # strip package:: prefix
        ln = lineno(src, m.start())

        # Update extends mapping
        kind = UVM_BASE_KIND.get(base_name) or class_kind_map.get(base_name)
        if kind is not None and kind in PARTITION:
            class_kind_map[cls_name] = kind
            entities.append(entity(kind, cls_name, abspath, ln,
                                   conf=0.90, src='static_parsed'))
            relations.append(relation('EXTENDS', kind, cls_name,
                                      class_kind_map.get(base_name, kind),
                                      base_name, conf=0.93, src='static_parsed'))

    # ── Coverage ──────────────────────────────────────────────────────────────

    for m in RE_COVERGRP.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        ln = lineno(src, m.start())
        # Detect sampling mechanism: if "with function sample" → explicit_call
        window = src[m.start():m.start()+200]
        if 'with function sample' in window:
            mech = 'explicit_call'
        elif '@' in window:
            mech = 'clocking_event'
        else:
            mech = 'explicit_call'
        entities.append(entity('COVERGROUP', name, abspath, ln,
                               props={'samplingMechanism': mech}))

    for m in RE_COVERPNT.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('COVERPOINT', name, abspath, lineno(src, m.start()),
                               conf=0.85))

    for m in RE_PROPERTY.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('SVA_PROPERTY', name, abspath, lineno(src, m.start())))

    for m in RE_SEQUENCE.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS or name.endswith('_vseq') or name.endswith('_seq'):
            # sequence keyword inside a UVM sequence body is different from SVA
            # only emit if not inside a class
            pass
        else:
            entities.append(entity('SVA_SEQUENCE', name, abspath,
                                   lineno(src, m.start()), conf=0.78))

    for m in RE_ASSERT.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('ASSERTION', name, abspath, lineno(src, m.start()),
                               props={'assertionType': 'assert'}))

    # ── Constraint blocks and rand vars ───────────────────────────────────────

    for m in RE_CONSTRAINT.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        # Skip out-of-class definitions: "constraint ClassName::name { ... }"
        after = src[m.end():m.end()+2]
        if after.startswith('::'):
            continue
        entities.append(entity('CONSTRAINT_BLOCK', name, abspath,
                               lineno(src, m.start()), conf=0.88))

    for m in RE_RANDVAR.finditer(src):
        name = m.group(1)
        if name in SV_KEYWORDS:
            continue
        entities.append(entity('RAND_VAR', name, abspath,
                               lineno(src, m.start()), conf=0.82))

    # ── Relations: bind ───────────────────────────────────────────────────────

    for m in RE_BIND.finditer(src):
        target_mod  = m.group(1)   # module being bound into
        checker_type = m.group(2)  # checker/assertion module type
        inst_name   = m.group(3)   # instance name
        ln = lineno(src, m.start())
        relations.append(relation('BOUND_TO', 'ASSERTION', checker_type,
                                  'MODULE', target_mod,
                                  conf=0.91, src='static_parsed'))

    # ── Relations: package imports ────────────────────────────────────────────

    pkg_file_module = None
    mods_in_file = [m.group(1) for m in RE_MODULE.finditer(src)
                    if m.group(1) not in SV_KEYWORDS]
    if mods_in_file:
        pkg_file_module = mods_in_file[0]

    for m in RE_PKG_USE.finditer(src):
        pkg = m.group(1)
        if pkg_file_module:
            relations.append(relation('USES_PACKAGE', 'MODULE', pkg_file_module,
                                      'PACKAGE', pkg, conf=0.80, src='heuristic'))

    # ── Relations: .sample() calls ────────────────────────────────────────────

    for m in RE_SAMPLE.finditer(src):
        cg_handle = m.group(1)
        if cg_handle in SV_KEYWORDS:
            continue
        relations.append(relation('SAMPLES', 'UVM_SCOREBOARD', fname.replace('.sv',''),
                                  'COVERGROUP', cg_handle,
                                  conf=0.65, src='heuristic'))

    # ── Gap 3: `uvm_do / `uvm_do_with → GENERATES ────────────────────────────

    # Build handle→type map from rand declarations in this file
    handle_type = {}
    for m in RE_RAND_TYPED.finditer(src):
        typ   = m.group(1).split('::')[-1]
        vname = m.group(2)
        if vname not in SV_KEYWORDS:
            handle_type[vname] = typ

    for m in RE_UVM_DO.finditer(src):
        handle = m.group(1)
        if handle in SV_KEYWORDS:
            continue
        cls_name, cls_kind = find_containing_class(src, m.start(), class_kind_map)
        if cls_name is None or cls_kind != 'UVM_SEQUENCE':
            continue
        item_type = handle_type.get(handle, handle)
        conf = 0.72 if handle in handle_type else 0.55
        relations.append(relation('GENERATES', 'UVM_SEQUENCE', cls_name,
                                  'UVM_SEQ_ITEM', item_type, conf=conf, src='heuristic'))

    # ── Gap 4: `uvm_declare_p_sequencer → RUNS_ON ────────────────────────────

    for m in RE_P_SEQ.finditer(src):
        seq_type = m.group(1)
        if seq_type in SV_KEYWORDS:
            continue
        cls_name, cls_kind = find_containing_class(src, m.start(), class_kind_map)
        if cls_name is None:
            continue
        relations.append(relation('RUNS_ON', cls_kind or 'UVM_SEQUENCE', cls_name,
                                  'UVM_SEQUENCER', seq_type, conf=0.90, src='static_parsed'))

    # ── Gap 5: type_id::create → CONTAINS ────────────────────────────────────

    for m in RE_CREATE.finditer(src):
        comp_type = m.group(1)
        comp_kind = class_kind_map.get(comp_type)
        if comp_kind is None:
            continue
        cls_name, cls_kind = find_containing_class(src, m.start(), class_kind_map)
        if cls_name is None:
            continue
        task_name = find_containing_task(src, m.start())
        in_build  = task_name is not None and 'build' in task_name.lower()
        conf = 0.78 if in_build else 0.55
        relations.append(relation('CONTAINS', cls_kind, cls_name,
                                  comp_kind, comp_type, conf=conf, src='heuristic'))

    # ── Gap 6a: run_phase objection tracking ──────────────────────────────────

    OBJ_CHECK_KINDS = frozenset({
        'UVM_DRIVER', 'UVM_MONITOR', 'UVM_TEST', 'UVM_SCOREBOARD', 'UVM_AGENT'
    })
    for ent in entities:
        if ent.get('kind') not in OBJ_CHECK_KINDS:
            continue
        cm = next((m for m in RE_CLASS.finditer(src) if m.group(1) == ent['name']), None)
        if not cm:
            continue
        ec = RE_ENDCLASS.search(src, cm.start())
        region = src[cm.start(): ec.end() if ec else len(src)]
        if not RE_RUN_PHASE.search(region):
            continue
        props = ent.setdefault('properties', {})
        props['raisesObjection'] = bool(re.search(r'\braise_objection\b', region))

    # ── Gap 6b: UVM_EVENT entities and PUBLISHES_TO / PULLS_FROM ─────────────

    evt_handles = set()

    for m in RE_UVM_EVT_GL.finditer(src):
        evt_name = m.group(1)
        entities.append(entity('UVM_EVENT', evt_name, abspath, lineno(src, m.start()),
                               conf=0.88, src='static_parsed'))
        # Inline direct chained call: get_global("name").trigger() / .wait_trigger()
        window = src[m.start(): m.start() + 100]
        cls_name, cls_kind = find_containing_class(src, m.start(), class_kind_map)
        if cls_name:
            if '.trigger(' in window:
                relations.append(relation('PUBLISHES_TO', cls_kind, cls_name,
                                          'UVM_EVENT', evt_name, conf=0.80, src='heuristic'))
            elif '.wait_trigger' in window:
                relations.append(relation('PULLS_FROM', cls_kind, cls_name,
                                          'UVM_EVENT', evt_name, conf=0.80, src='heuristic'))

    for m in RE_UVM_EVT_DECL.finditer(src):
        evt_name = m.group(1)
        if evt_name in SV_KEYWORDS:
            continue
        evt_handles.add(evt_name)
        entities.append(entity('UVM_EVENT', evt_name, abspath, lineno(src, m.start()),
                               conf=0.82, src='static_parsed'))

    for m in RE_TRIGGER.finditer(src):
        handle = m.group(1)
        if handle not in evt_handles:
            continue
        cls_name, cls_kind = find_containing_class(src, m.start(), class_kind_map)
        if cls_name:
            relations.append(relation('PUBLISHES_TO', cls_kind, cls_name,
                                      'UVM_EVENT', handle, conf=0.75, src='heuristic'))

    for m in RE_WAIT_TRIG.finditer(src):
        handle = m.group(1)
        if handle not in evt_handles:
            continue
        cls_name, cls_kind = find_containing_class(src, m.start(), class_kind_map)
        if cls_name:
            relations.append(relation('PULLS_FROM', cls_kind, cls_name,
                                      'UVM_EVENT', handle, conf=0.75, src='heuristic'))

    return entities, relations

# ── Two-pass extraction ───────────────────────────────────────────────────────

def extract_dir(root):
    sv_files = list(Path(root).rglob('*.sv')) + list(Path(root).rglob('*.svh'))
    # Pass 1: collect all class→kind mappings
    class_kind_map = {}
    for f in sv_files:
        try:
            src = strip_comments(Path(f).read_text(errors='replace'))
        except Exception:
            continue
        for m in RE_CLASS.finditer(src):
            cls  = m.group(1)
            base = m.group(2).split('::')[-1]
            kind = UVM_BASE_KIND.get(base)
            if kind:
                class_kind_map[cls] = kind

    # Resolve one level of transitivity (B extends A → C extends B gets A's kind)
    changed = True
    while changed:
        changed = False
        try:
            src_all = '\n'.join(
                strip_comments(Path(f).read_text(errors='replace'))
                for f in sv_files
            )
        except Exception:
            break
        for m in RE_CLASS.finditer(src_all):
            cls  = m.group(1)
            base = m.group(2).split('::')[-1]
            if cls not in class_kind_map and base in class_kind_map:
                class_kind_map[cls] = class_kind_map[base]
                changed = True

    # Pass 2: extract entities and relations
    all_entities = []
    all_relations = []
    for f in sv_files:
        ents, rels = extract_file(f, class_kind_map)
        all_entities.extend(ents)
        all_relations.extend(rels)

    return all_entities, all_relations

# ── Main ─────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('usage: extractor.py <dir> [<dir>...]', file=sys.stderr)
        sys.exit(1)

    total_e = 0
    total_r = 0
    for root in sys.argv[1:]:
        ents, rels = extract_dir(root)
        for e in ents:
            emit(e)
            total_e += 1
        for r in rels:
            emit(r)
            total_r += 1

    print(f'# extracted {total_e} entities, {total_r} relations', file=sys.stderr)

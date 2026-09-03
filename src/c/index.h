#pragma once
#include "tok.h"
#include "infer.h"
#include "db.h"
#include <stdint.h>

/*
 * File indexer: tokenize → NER → entity extraction → PostgreSQL insert.
 *
 * index_dir() walks a directory tree, processes every .sv/.v/.svh/.uvm file,
 * and inserts discovered entities into the 'entities' table.
 *
 * Results are printed to stderr as they arrive.
 */

/* Index one source file.
 * Returns number of entities inserted (≥0) or -1 on error. */
int krl_index_file(KrlRuntime *rt, KrlTok *tok, KrlDb *db,
                   int64_t project_id, const char *file_path);

/* Walk dir_path recursively, indexing all SV/UVM files found.
 * Returns total entities inserted across all files, or -1 on fatal error. */
int krl_index_dir(KrlRuntime *rt, KrlTok *tok, KrlDb *db,
                  int64_t project_id, const char *dir_path);

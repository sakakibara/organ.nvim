-- v1 schema (initial public release). Database-first architecture: the
-- file-system is source, SQLite is the index, the buffer is a view. Every
-- agenda/roam operation is a query.
--
-- This is the BASELINE. Any future schema change ships as a vN→vN+1
-- migration in lua/organ/init.lua. The migrations module starts empty.
--
-- NOTE: connection-level PRAGMAs (foreign_keys, journal_mode, synchronous,
-- busy_timeout, etc.) are applied by lua/organ/db.lua at open time and are
-- intentionally NOT in this file. Only creation-time PRAGMAs belong here.

PRAGMA page_size = 8192;
PRAGMA auto_vacuum = INCREMENTAL;

CREATE TABLE IF NOT EXISTS files (
  path     TEXT PRIMARY KEY,
  mtime    INTEGER NOT NULL,
  hash     TEXT NOT NULL,
  indexed  INTEGER NOT NULL,
  -- Hash of the (parser binary mtime + indexer.lua source + schema)
  -- used to extract this file.  Invalidates mtime/hash-skip when our
  -- extract pipeline changes underneath the user — without this, a
  -- file indexed against an older grammar stays cached forever
  -- because its mtime on disk hasn't changed.  NULLABLE for
  -- backwards-compat with rows from older organ versions; rows with
  -- a NULL value or one that doesn't match the current version are
  -- treated as stale and force-re-extracted on the next pass.
  extractor_version TEXT
);

CREATE INDEX IF NOT EXISTS idx_files_mtime ON files(mtime);

CREATE TABLE IF NOT EXISTS headlines (
  id              TEXT PRIMARY KEY,
  file_path       TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  parent_id       TEXT REFERENCES headlines(id) ON DELETE CASCADE,
  level           INTEGER NOT NULL,
  title           TEXT NOT NULL,
  todo_state      TEXT,
  priority        TEXT,
  scheduled       TEXT,
  deadline        TEXT,
  closed          TEXT,
  scheduled_date  TEXT,
  deadline_date   TEXT,
  closed_date     TEXT,
  line_start      INTEGER NOT NULL,
  line_end        INTEGER NOT NULL,
  -- 1 when the headline starts with the literal `COMMENT` keyword
  -- (`* COMMENT Foo` or `* TODO COMMENT Foo`).  Mirrors Emacs's
  -- `org-comment-string` — the entire subtree is excluded from
  -- agenda / export when `org-agenda-skip-comment-trees` is on.
  commented       INTEGER NOT NULL DEFAULT 0,
  UNIQUE(file_path, line_start)
);

CREATE INDEX IF NOT EXISTS idx_headlines_file           ON headlines(file_path);
CREATE INDEX IF NOT EXISTS idx_headlines_todo           ON headlines(todo_state)     WHERE todo_state     IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_headlines_scheduled      ON headlines(scheduled)      WHERE scheduled      IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_headlines_deadline       ON headlines(deadline)       WHERE deadline       IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_headlines_parent         ON headlines(parent_id);
CREATE INDEX IF NOT EXISTS idx_headlines_scheduled_date ON headlines(scheduled_date) WHERE scheduled_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_headlines_deadline_date  ON headlines(deadline_date)  WHERE deadline_date  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_headlines_closed_date    ON headlines(closed_date)    WHERE closed_date    IS NOT NULL;

CREATE TABLE IF NOT EXISTS tags (
  headline_id TEXT NOT NULL REFERENCES headlines(id) ON DELETE CASCADE,
  tag         TEXT NOT NULL,
  PRIMARY KEY (headline_id, tag)
);

CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);

CREATE TABLE IF NOT EXISTS properties (
  headline_id TEXT NOT NULL REFERENCES headlines(id) ON DELETE CASCADE,
  key         TEXT NOT NULL,
  value       TEXT,
  PRIMARY KEY (headline_id, key)
);

CREATE INDEX IF NOT EXISTS idx_properties_key ON properties(key);

CREATE TABLE IF NOT EXISTS links (
  source_headline_id TEXT NOT NULL REFERENCES headlines(id) ON DELETE CASCADE,
  target_type        TEXT NOT NULL,
  target             TEXT NOT NULL,
  description        TEXT,
  line               INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_links_source    ON links(source_headline_id);
CREATE INDEX IF NOT EXISTS idx_links_id_target ON links(target) WHERE target_type = 'id';

CREATE TABLE IF NOT EXISTS clock_entries (
  headline_id      TEXT    NOT NULL REFERENCES headlines(id) ON DELETE CASCADE,
  start_ts         INTEGER NOT NULL,
  end_ts           INTEGER,
  duration_seconds INTEGER,
  PRIMARY KEY (headline_id, start_ts)
);

CREATE INDEX IF NOT EXISTS idx_clock_entries_start
  ON clock_entries(start_ts);
CREATE INDEX IF NOT EXISTS idx_clock_entries_active
  ON clock_entries(headline_id) WHERE end_ts IS NULL;

-- State-change events parsed from each headline's :LOGBOOK: drawer.
-- One row per `- State "X" from "Y" [...]` entry.  Powers Emacs
-- `org-agenda-log-mode-items = state` and any per-headline state
-- audit reporting.  `from_state` is empty / NULL when the line is a
-- `from ""` (transitioning into a TODO state from no state).
CREATE TABLE IF NOT EXISTS state_changes (
  headline_id TEXT    NOT NULL REFERENCES headlines(id) ON DELETE CASCADE,
  ts          INTEGER NOT NULL,
  from_state  TEXT,
  to_state    TEXT    NOT NULL,
  note        TEXT,
  PRIMARY KEY (headline_id, ts, to_state)
);

CREATE INDEX IF NOT EXISTS idx_state_changes_ts
  ON state_changes(ts);
CREATE INDEX IF NOT EXISTS idx_state_changes_headline
  ON state_changes(headline_id);

CREATE TABLE IF NOT EXISTS file_tags (
  file_path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  tag       TEXT NOT NULL,
  PRIMARY KEY (file_path, tag)
);

CREATE INDEX IF NOT EXISTS idx_file_tags_tag ON file_tags(tag);

CREATE TABLE IF NOT EXISTS aliases (
  headline_id TEXT NOT NULL REFERENCES headlines(id) ON DELETE CASCADE,
  alias       TEXT NOT NULL,
  PRIMARY KEY (headline_id, alias)
);
CREATE INDEX IF NOT EXISTS idx_aliases_alias ON aliases(alias);

CREATE TABLE IF NOT EXISTS habit_completions (
  headline_id TEXT NOT NULL REFERENCES headlines(id) ON DELETE CASCADE,
  date        TEXT NOT NULL,
  PRIMARY KEY (headline_id, date)
);
CREATE INDEX IF NOT EXISTS idx_habit_completions_date
  ON habit_completions(date);

-- Per-file `#+TODO:` directive keywords.  One row per (file, sequence_idx,
-- ordinal) so multi-sequence files (`#+TODO: A | B` then `#+TODO: X | Y`)
-- preserve membership and active/done classification.  `is_done = 1` for
-- keywords appearing AFTER the `|` divider in their sequence.  Powers the
-- agenda's per-row done classification without re-reading source files.
CREATE TABLE IF NOT EXISTS file_todo_keywords (
  file_path     TEXT    NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  sequence_idx  INTEGER NOT NULL,
  ordinal       INTEGER NOT NULL,
  keyword       TEXT    NOT NULL,
  is_done       INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (file_path, sequence_idx, ordinal)
);
CREATE INDEX IF NOT EXISTS idx_file_todo_keywords_kw
  ON file_todo_keywords(keyword);

PRAGMA user_version = 1;

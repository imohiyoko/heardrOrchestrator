-- 008: PR 作成キュー(tb pr-queue)。agent が依頼を置き、人が承認し、scheduler の tb pr-queue run が draft PR を作る
CREATE TABLE pr_queue (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  repo         TEXT NOT NULL,
  branch       TEXT NOT NULL,
  title        TEXT NOT NULL,
  body_file    TEXT NOT NULL,
  body_sha256  TEXT NOT NULL,
  task_id      TEXT,
  requested_by TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('pending','approved','rejected','created','failed')),
  last_error   TEXT,
  attempts     INTEGER NOT NULL DEFAULT 0,
  pr_url       TEXT,
  created_at   TEXT NOT NULL,
  decided_at   TEXT,
  executed_at  TEXT
);
CREATE INDEX IF NOT EXISTS pr_queue_status ON pr_queue(status);

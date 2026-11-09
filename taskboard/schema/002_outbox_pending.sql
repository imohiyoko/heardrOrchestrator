-- 002: outbox.status に 'pending'(人の承認待ち)を足す前に作られた DB の outbox を作り直す
-- SQLite は CHECK を ALTER できないため、作り直して行を移す。001 で作った DB では中身がそのまま移るだけ
CREATE TABLE outbox_new (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  from_name    TEXT NOT NULL,                 -- herdr agent list から引いた値(自己申告ではない)
  from_pane    TEXT NOT NULL,
  from_session TEXT NOT NULL,
  target       TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('task','info','answer')),
  task_id      TEXT,
  text         TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('pending','queued','sent','denied')),   -- pending = 人の承認待ち
  reason       TEXT,                          -- 許可・拒否の根拠(routes.conf の行など)
  sent_at      TEXT,
  created_at   TEXT NOT NULL
);
INSERT INTO outbox_new (id, from_name, from_pane, from_session, target, kind, task_id, text, status, reason, sent_at, created_at) SELECT id, from_name, from_pane, from_session, target, kind, task_id, text, status, reason, sent_at, created_at FROM outbox;
DROP TABLE outbox;
ALTER TABLE outbox_new RENAME TO outbox;
CREATE INDEX IF NOT EXISTS outbox_status ON outbox(status);

-- 007: agent_ops に op=compact(tb compact-check が送った /compact の記録)を足す。CHECK 制約は作り直しでしか変えられない
CREATE TABLE agent_ops_new (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  op           TEXT NOT NULL CHECK (op IN ('new','stop','revive','compact')),
  target       TEXT NOT NULL,
  args         TEXT NOT NULL DEFAULT '{}',
  requested_by TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('pending','done','failed','rejected')),
  result       TEXT,
  created_at   TEXT NOT NULL,
  decided_at   TEXT
);
INSERT INTO agent_ops_new (id, op, target, args, requested_by, status, result, created_at, decided_at)
  SELECT id, op, target, args, requested_by, status, result, created_at, decided_at FROM agent_ops;
DROP TABLE agent_ops;
ALTER TABLE agent_ops_new RENAME TO agent_ops;
CREATE INDEX IF NOT EXISTS agent_ops_status ON agent_ops(status);

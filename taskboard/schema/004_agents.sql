-- 004: agent の台帳(停止・復活・新規作成)と、止めてよいかの判定フラグ、操作の記録・承認待ち
CREATE TABLE IF NOT EXISTS agents (
  name             TEXT PRIMARY KEY,               -- herdr の agent 名
  kind             TEXT NOT NULL DEFAULT 'claude',
  cwd              TEXT,                           -- 復活時の作業ディレクトリ(--resume は同じ場所でないと会話が見つからない)
  model            TEXT,                           -- tb agent-new / revive で指定したモデル
  role             TEXT,                           -- tb agent-new --role(roles/<role>.md)。無ければ名前と map.conf で決まる
  session_id       TEXT,                           -- 最後に見た会話(herdr の agent_session)。復活で --resume に渡す
  pane_id          TEXT,
  herdr_session    TEXT NOT NULL DEFAULT 'default', -- どの herdr セッション(HERDR_SESSION)の agent か。別セッションのものは同期・操作しない
  state            TEXT NOT NULL CHECK (state IN ('running','stopped')),
  killable         TEXT NOT NULL DEFAULT 'unknown' CHECK (killable IN ('yes','no','unknown')),
  killable_reason  TEXT,
  killable_by      TEXT,                           -- 判定役の名前 / human / tb
  killable_at      TEXT,
  killable_session TEXT,                           -- 判定したときの会話。変わっていたら判定は無効(stale)
  created_by       TEXT NOT NULL,                  -- human / agent 名 / tb / herdr(tb 以外で起動されたものを見つけた)
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL,
  stopped_at       TEXT
);
CREATE TABLE IF NOT EXISTS agent_ops (           -- 停止・復活・新規作成の記録。agent からの依頼で人の承認待ちのものは pending
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  op           TEXT NOT NULL CHECK (op IN ('new','stop','revive')),
  target       TEXT NOT NULL,
  args         TEXT NOT NULL DEFAULT '{}',          -- JSON(cwd / model / role / prompt / killable / force / fresh)
  requested_by TEXT NOT NULL,                       -- human か、herdr から引いた agent 名
  status       TEXT NOT NULL CHECK (status IN ('pending','done','failed','rejected')),
  result       TEXT,
  created_at   TEXT NOT NULL,
  decided_at   TEXT
);
CREATE INDEX IF NOT EXISTS agent_ops_status ON agent_ops(status);

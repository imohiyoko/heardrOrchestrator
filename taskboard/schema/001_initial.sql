-- 001: 初期スキーマ(リファクタ前の tb の init_db と同じ内容)
-- 既存 DB(user_version=0)にも流れるので、すべて IF NOT EXISTS にしておく
CREATE TABLE IF NOT EXISTS tasks (
  id           TEXT PRIMARY KEY,
  project      TEXT NOT NULL,
  title        TEXT NOT NULL,
  owner_agent  TEXT,
  session_id   TEXT,
  account      TEXT,
  status       TEXT NOT NULL DEFAULT 'todo'
               CHECK (status IN ('todo','in_progress','review','done','blocked')),
  parent_id    TEXT,
  deliverables TEXT NOT NULL DEFAULT '[]',   -- JSON 配列
  summary      TEXT,                          -- done 時の要約
  note         TEXT,                          -- block 理由など
  reported_at  TEXT,                          -- report 成功時のみ埋まる
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS tasks_project_status ON tasks(project, status);
CREATE TABLE IF NOT EXISTS proxy_requests (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id    TEXT NOT NULL,
  cmd        TEXT NOT NULL,
  why        TEXT NOT NULL,
  effect     TEXT NOT NULL CHECK (effect IN ('read-only','write','external')),
  expect     TEXT,
  status     TEXT NOT NULL DEFAULT 'open'
             CHECK (status IN ('open','done','pending-human','denied')),
  result     TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS proxy_requests_status ON proxy_requests(status);
CREATE TABLE IF NOT EXISTS comments (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id      TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('done','progress','question','blocked')),
  text         TEXT NOT NULL,
  deliverables TEXT NOT NULL DEFAULT '[]',   -- JSON 配列(done で必須)
  from_name    TEXT NOT NULL,                 -- herdr agent list から引いた値(自己申告ではない)
  from_pane    TEXT NOT NULL,
  from_session TEXT NOT NULL,
  delivered_at TEXT,                          -- 宛先へ送れたときだけ埋まる
  created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS comments_task ON comments(task_id);
CREATE TABLE IF NOT EXISTS agent_activity (
  session_id     TEXT PRIMARY KEY,
  pane_id        TEXT,
  tab_id         TEXT,
  workspace_id   TEXT,
  cwd            TEXT,
  last_prompt_id TEXT,
  last_prompt_at TEXT,    -- UserPromptSubmit の時刻(UTC, ミリ秒)
  last_stop_at   TEXT,    -- Stop の時刻
  updated_at     TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (       -- tb が送ろうとしたものすべて(送れたか否かも)
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL,                  -- report|comment|digest|send|role|alert|scheduler|proposal
  ref        TEXT,                           -- T-.. / C-.. / D-..
  target     TEXT NOT NULL,
  body       TEXT NOT NULL,
  result     TEXT NOT NULL CHECK (result IN ('sent','busy','failed')),
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS outbox (          -- tb send(指揮官 → worker)。拒否したものも残す
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
CREATE INDEX IF NOT EXISTS outbox_status ON outbox(status);
CREATE TABLE IF NOT EXISTS approval_changes ( -- tb allow / tb ask の履歴(人が実行したもの)
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  pattern    TEXT NOT NULL,
  value      TEXT NOT NULL CHECK (value IN ('ask','allow')),
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS role_briefings ( -- 役割をいつ誰(どのセッション)にどの版で渡したか
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  agent      TEXT NOT NULL,
  role_file  TEXT,                           -- roles/ からの相対パス(共通のみなら NULL)
  hash       TEXT NOT NULL,                  -- 渡した内容(_common + 役割)の SHA-256
  source     TEXT NOT NULL,                  -- startup|resume|clear|compact|broadcast
  via        TEXT NOT NULL CHECK (via IN ('hook','broadcast')),
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS role_briefings_session ON role_briefings(session_id);
CREATE TABLE IF NOT EXISTS alerts (         -- 見張り役が登録した異常と、その解析
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  fingerprint   TEXT NOT NULL,                -- --key(無ければ題名)の SHA-256 先頭。未解決の同じ指紋はまとめる
  severity      TEXT CHECK (severity IS NULL OR severity IN ('critical','high','medium','low')),   -- 解析役が決める
  title         TEXT NOT NULL,
  body          TEXT,
  source        TEXT NOT NULL,                -- 報告した agent 名(herdr から)か cli
  source_pane   TEXT,
  status        TEXT NOT NULL CHECK (status IN ('new','awaiting-approval','approved','queued','analyzing','analyzed','closed')),
  count         INTEGER NOT NULL DEFAULT 1,
  analyst       TEXT,
  note          TEXT,
  result_summary TEXT, result_report TEXT, result_path TEXT, result_by TEXT, result_delivered_at TEXT,
  first_seen TEXT NOT NULL, last_seen TEXT NOT NULL, analysis_started_at TEXT, analyzed_at TEXT, closed_at TEXT
);
CREATE INDEX IF NOT EXISTS alerts_status ON alerts(status);
CREATE TABLE IF NOT EXISTS proposals (      -- 会計役 → 設定役(人事)のプロンプト改善提案
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  role_file    TEXT NOT NULL,                 -- roles/ のファイル名(全体なら -)
  title        TEXT NOT NULL,
  text         TEXT NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('open','applied','rejected')),
  by_name      TEXT NOT NULL,                 -- herdr から引いた提案者
  note         TEXT,
  delivered_at TEXT, resolved_at TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS reviews (        -- review-pack --mark の区切り(次回はここから)
  id INTEGER PRIMARY KEY AUTOINCREMENT, since_at TEXT NOT NULL, until_at TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS digests (        -- まとめ送信 1 通ごと。body は複数行の全文
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  target     TEXT NOT NULL,
  item_count INTEGER NOT NULL,
  body       TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS observations (   -- tb が観測して送った事象(同じものを二度送らない)
  key        TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,                  -- idle|stuck|blocked
  task_id    TEXT,
  text       TEXT NOT NULL,
  digest_id  INTEGER,
  created_at TEXT NOT NULL
);

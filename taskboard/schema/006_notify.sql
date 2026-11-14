-- 006: 外部への通知(tb notify)。イベントのキュー、送信の記録、pr-watch が見た状態
CREATE TABLE IF NOT EXISTS notify_events (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  type           TEXT NOT NULL,                  -- alert_raised|alert_result|pr_opened|...|digest|test|warning
  ref            TEXT,                           -- A-1 / C-3 / T-.. / owner/repo#12 など
  severity       TEXT,
  text           TEXT NOT NULL,                  -- 整形・フィルタ済みの本文(blocked のときは秘密を伏せたもの)
  hash           TEXT NOT NULL,                  -- 本文の sha256 の先頭 12 字
  blocked        INTEGER NOT NULL DEFAULT 0,     -- 1 = 秘密らしい値を検出。外へは出さない(file にだけ残す)
  blocked_reason TEXT,
  sinks          TEXT NOT NULL,                  -- 空白区切り(file stdout slack)
  dedupe_key     TEXT,
  file_at        TEXT,
  slack_status   TEXT NOT NULL DEFAULT 'none',   -- none|pending|awaiting-ack|acked|sent|batched|failed|mismatch
  slack_attempts INTEGER NOT NULL DEFAULT 0,
  slack_sent_at  TEXT,
  slack_msg_id   TEXT,
  batch_id       INTEGER,                        -- まとめて送ったときの、まとめの event id
  note           TEXT,
  created_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS notify_events_status ON notify_events(slack_status);
CREATE INDEX IF NOT EXISTS notify_events_dedupe ON notify_events(dedupe_key, created_at);
CREATE TABLE IF NOT EXISTS notify_sends (          -- 外へ出した 1 回ごとの記録(頻度の上限の計算に使う)
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id INTEGER NOT NULL,
  via      TEXT NOT NULL,
  at       TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS notify_seen (           -- pr-watch が前回見た状態、定期まとめの前回の値
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- 003: 人が question / blocked の報告を「対応済み」にできるようにする(tb resolve / Web UI のボタン)
ALTER TABLE comments ADD COLUMN resolved_at TEXT;     -- 人が対応済みにした時刻。NULL = 未対応
ALTER TABLE comments ADD COLUMN resolved_note TEXT;   -- そのときのメモ(任意)

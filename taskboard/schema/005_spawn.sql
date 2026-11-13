-- 005: agent-spawn(規則つきの子 agent 作成)。親子の記録と、自動承認を止めるフラグ
ALTER TABLE agents ADD COLUMN spawned_by TEXT;     -- tb agent-spawn で立てた子の親の名前。tb comment が指揮官に親を伝えるのに使う
ALTER TABLE agents ADD COLUMN spawn_task TEXT;     -- 子に任せたタスク ID(親のタスク)
CREATE INDEX IF NOT EXISTS agents_spawned_by ON agents(spawned_by);
CREATE TABLE IF NOT EXISTS tb_flags (              -- 人が立てる小さなフラグ(spawn_frozen など)
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL,
  set_by TEXT,
  set_at TEXT NOT NULL
);

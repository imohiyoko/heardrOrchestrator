# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- スキーマの版(taskboard/schema/NNN_*.sql と PRAGMA user_version)
export TB_DB=$TMP/schema.db
latest=$(ls "$HERE/../schema"/[0-9][0-9][0-9]_*.sql | tail -n 1 | xargs basename | cut -c1-3); latest=$((10#$latest))
$TB list >/dev/null
eq "schema: fresh DB is at the latest version" "$(sqlite3 "$TB_DB" "PRAGMA user_version;")" "$latest"
eq "schema: every table exists" "$(sqlite3 "$TB_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('tasks','proxy_requests','comments','agent_activity','messages','outbox','approval_changes','role_briefings','alerts','proposals','reviews','digests','observations');")" "13"
# リファクタ前の tb が作った DB(全テーブルあり・user_version=0)は中身を保ったまま最新になる
rm -f "$TB_DB"; sqlite3 "$TB_DB" <"$HERE/../schema/001_initial.sql"
sqlite3 "$TB_DB" "INSERT INTO tasks (id, project, title, created_at, updated_at) VALUES ('T-old-001','old','keep','t','t');
  INSERT INTO outbox (from_name, from_pane, from_session, target, kind, text, status, created_at) VALUES ('c','p','s','w','info','x','pending','t');"
eq "schema: pre-versioned DB keeps rows" "$($TB show T-old-001 | jq -r .title) $(sqlite3 "$TB_DB" "SELECT status FROM outbox;") $(sqlite3 "$TB_DB" "PRAGMA user_version;")" "keep pending $latest"
eq "schema: outbox index survives migration" "$(sqlite3 "$TB_DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='outbox_status';")" "1"
# 版が最新なら何も流さない(DDL を流すと sqlite_master が変わる)
before=$(sqlite3 "$TB_DB" "PRAGMA schema_version;"); $TB list >/dev/null
eq "schema: up-to-date DB is not touched" "$(sqlite3 "$TB_DB" "PRAGMA schema_version;")" "$before"
# 移行に失敗したら止まり、版は進まない
mkdir -p "$TMP/badschema"; cp "$HERE/../schema"/*.sql "$TMP/badschema/"
printf 'CREATE TABLE broken (;\n' >"$TMP/badschema/999_broken.sql"
eq "schema: failed migration → exit 1" "$(TB_SCHEMA_DIR=$TMP/badschema rc $TB list)" "1"
eq "schema: failed migration keeps the version" "$(sqlite3 "$TB_DB" "PRAGMA user_version;")" "$latest"
# 別の tb が先に移行を済ませていたら、同じ移行を二度流さない(ロック後の版の確認)
printf 'INSERT INTO tasks (id, project, title, created_at, updated_at) VALUES (%s);\n' "'T-dup-001','dup','x','t','t'" >"$TMP/badschema/999_broken.sql"
sqlite3 "$TB_DB" "PRAGMA user_version=999;"
( source "$HERE/../lib/db.sh"; migration_sql 999 "$TMP/badschema/999_broken.sql" ) | sqlite3 -bail "$TB_DB" >/dev/null 2>&1; r=$?
eq "schema: guard stops a migration that already ran" "$([[ $r -ne 0 ]] && echo stopped) $(sqlite3 "$TB_DB" "SELECT COUNT(*) FROM tasks WHERE id='T-dup-001';")" "stopped 0"
eq "schema: already migrated → tb still works" "$(TB_SCHEMA_DIR=$TMP/badschema rc $TB list)" "0"
mkdir -p "$TMP/noschema"
eq "schema: no schema files → exit 1, no DB file" "$(TB_DB=$TMP/none/x.db TB_SCHEMA_DIR=$TMP/noschema rc $TB list) $([[ -e $TMP/none ]] && echo created || echo absent)" "1 absent"
export TB_DB=$TMP/old.db

# shellcheck shell=bash
# DB 層: 接続・SQL リテラル化・スキーマの移行。tb から source される。
# スキーマは $HERDR_SCHEMA_DIR/NNN_*.sql(テストでは TB_SCHEMA_DIR で差し替え)。DB の PRAGMA user_version より新しい番号だけを順に流す。
# 新しい変更は既存ファイルを書き換えず、次の番号のファイルを足す。

sql() { sqlite3 -bail -batch -cmd ".timeout ${SQL_TIMEOUT:-5000}" "$DB" "$@"; }
q()   { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }          # SQL 文字列リテラル化

schema_files() { local f; for f in "${TB_SCHEMA_DIR:-$HERDR_SCHEMA_DIR}"/[0-9][0-9][0-9]_*.sql; do [[ -f $f ]] && printf '%s\n' "$f"; done; }
schema_latest() { local f n=0; f=$(schema_files | tail -n 1); [[ -n $f ]] && n=$((10#$(basename "$f" | cut -c1-3))); echo "$n"; }

# 移行 1 本分の SQL。ロックを取った直後に版を確かめ、別の tb が先に済ませていたら CHECK 違反で何も流さずに止まる
migration_sql() {  # $1=番号 $2=ファイル
  echo "BEGIN IMMEDIATE;"
  echo "CREATE TEMP TABLE _tb_migrate_guard (v INTEGER CHECK (v < $1)); INSERT INTO _tb_migrate_guard SELECT user_version FROM pragma_user_version;"
  cat "$2"
  echo "PRAGMA user_version=$1; COMMIT;"
}

# 最新なら PRAGMA 1 回で戻る(hook から毎回呼ばれるので軽くしておく)
init_db() {
  mkdir -p "$(dirname "$DB")"
  local v latest f n err
  v=$(sql "PRAGMA user_version;") || return 1
  latest=$(schema_latest)
  ((latest > 0)) || { echo "tb: スキーマのファイルが見つかりません: ${TB_SCHEMA_DIR:-$HERDR_SCHEMA_DIR}" >&2; return 1; }
  ((v >= latest)) && return 0
  while IFS= read -r f; do
    n=$((10#$(basename "$f" | cut -c1-3)))
    ((n > v)) || continue
    # 失敗しても、別の tb が先に済ませて版が進んでいれば良しとする
    if ! err=$(migration_sql "$n" "$f" | sql 2>&1 >/dev/null); then
      v=$(sql "PRAGMA user_version;") || return 1
      ((v >= n)) || { echo "tb: 移行 $(basename "$f") に失敗: $err" >&2; return 1; }
    fi
    v=$n
  done < <(schema_files)
}

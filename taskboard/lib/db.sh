# shellcheck shell=bash
# DB 層: 接続・SQL リテラル化・スキーマの移行。tb から source される。
# スキーマは $HERDR_SCHEMA_DIR/NNN_*.sql(テストでは TB_SCHEMA_DIR で差し替え)。DB の PRAGMA user_version より新しい番号だけを順に流す。
# 新しい変更は既存ファイルを書き換えず、次の番号のファイルを足す。

sql() { sqlite3 -bail -batch -cmd ".timeout ${SQL_TIMEOUT:-5000}" "$DB" "$@"; }
q()   { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }          # SQL 文字列リテラル化

schema_files() { local f; for f in "${TB_SCHEMA_DIR:-$HERDR_SCHEMA_DIR}"/[0-9][0-9][0-9]_*.sql; do [[ -f $f ]] && printf '%s\n' "$f"; done; }
schema_latest() { local f n=0; f=$(schema_files | tail -n 1); [[ -n $f ]] && n=$((10#$(basename "$f" | cut -c1-3))); echo "$n"; }

# 最新なら PRAGMA 1 回で戻る(hook から毎回呼ばれるので軽くしておく)
init_db() {
  mkdir -p "$(dirname "$DB")"
  local v latest f n
  v=$(sql "PRAGMA user_version;") || return 1
  latest=$(schema_latest)
  ((v >= latest)) && return 0
  while IFS= read -r f; do
    n=$((10#$(basename "$f" | cut -c1-3)))
    ((n > v)) || continue
    # 同時に別の tb が移行していたら、失敗しても版が進んでいれば良しとする
    if ! { echo "BEGIN IMMEDIATE;"; cat "$f"; echo "PRAGMA user_version=$n; COMMIT;"; } | sql >/dev/null; then
      v=$(sql "PRAGMA user_version;") || return 1
      ((v >= n)) || return 1
    fi
    v=$n
  done < <(schema_files)
}

#!/bin/bash
# tick.sh の判定テスト。DRY_RUN=1 + NOW 差し替えのみ。herdr は呼ばない。
# 使い方: tests/run.sh
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export JOBS_DIR="$TMP/jobs" LOG_DIR="$TMP/logs"; mkdir -p "$JOBS_DIR"

cat >"$JOBS_DIR/t.conf" <<'C'
TARGET=dummy
PROMPT='do the thing'
WINDOW=09:00-21:00
INTERVAL_MIN=5
C
cat >"$JOBS_DIR/wk.conf" <<'C'
TARGET=dummy
PROMPT='do the thing'
WINDOW=09:00-21:00
INTERVAL_MIN=5
DAYS="Mon Tue Wed Thu Fri"
C
cat >"$JOBS_DIR/skipidle.conf" <<'C'
TARGET=dummy
PROMPT='do the thing'
WINDOW=09:00-21:00
INTERVAL_MIN=5
SKIP_IF="working blocked done"
C
cat >"$JOBS_DIR/slash.conf" <<'C'
TARGET=dummy
PROMPT='/loop bad'
WINDOW=09:00-21:00
INTERVAL_MIN=5
C

pass=0; failn=0
# check <説明> <期待 action> <job> <NOW> [FAKE_STATE]
check() {
  local desc=$1 want=$2 job=$3 now=$4 st=${5:-} got
  got=$(DRY_RUN=1 NOW="$now" FAKE_STATE="$st" bash bin/tick.sh "$job" 2>&1 | jq -r .action 2>&1)
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); printf 'ok   %-46s %s -> %s\n' "$desc" "$now" "$got"
  else failn=$((failn + 1)); printf 'FAIL %-46s %s want=%s got=%s\n' "$desc" "$now" "$want" "$got"; fi
}

ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else failn=$((failn + 1)); echo "FAIL $1 want=[$3] got=[$2]"; fi; }

THU="2026-11-05"; SAT="2026-11-07"; SUN="2026-11-08"; MON="2026-11-09"
# 窓の境界(木曜、状態 idle)
check "境界 08:55 は窓の外"        skipped_window t "$THU 08:55" idle
check "境界 09:00 は実行(始端を含む)" sent           t "$THU 09:00" idle
check "境界 20:55 は実行"          sent           t "$THU 20:55" idle
check "境界 21:00 は実行(終端を含む)" sent           t "$THU 21:00" idle
check "境界 21:05 は窓の外"        skipped_window t "$THU 21:05" idle
check "ISO 形式の NOW (T 区切り)"    sent           t "${THU}T12:00" idle
# DAYS
check "DAYS 平日: 木曜は実行"       sent           wk "$THU 12:00" idle
check "DAYS 平日: 土曜は外"        skipped_window wk "$SAT 12:00" idle
check "DAYS 平日: 日曜は外"        skipped_window wk "$SUN 12:00" idle
check "DAYS 平日: 月曜は実行"       sent           wk "$MON 12:00" idle
check "DAYS 既定(毎日): 日曜も実行"  sent           t  "$SUN 12:00" idle
# SKIP_IF / 状態
check "SKIP_IF 既定: working は skip" skipped_state t "$THU 12:00" working
check "SKIP_IF 既定: blocked は skip" skipped_state t "$THU 12:00" blocked
check "idle は送る"                sent           t "$THU 12:00" idle
check "done は送る"                sent           t "$THU 12:00" done
check "unknown は idle/done でないので skip" skipped_state t "$THU 12:00" unknown
check "SKIP_IF 上書き: done を skip"  skipped_state skipidle "$THU 12:00" done
check "SKIP_IF 上書き: idle は送る"   sent           skipidle "$THU 12:00" idle
check "窓の外は状態に関わらず外"      skipped_window t "$THU 22:00" idle
# 本文の安全装置
check "先頭が / の本文は failed"     failed         slash "$THU 12:00" idle

# DRY_RUN はログを書かない
[ ! -e "$LOG_DIR/t.log" ] && { pass=$((pass + 1)); echo "ok   DRY_RUN はログを書かない"; } \
  || { failn=$((failn + 1)); echo "FAIL DRY_RUN がログを書いた"; }

# gen-plist: 毎分起動(空の StartCalendarInterval)。時間帯・間隔は tick.sh が判定する
OUT_DIR="$TMP/gen" bash bin/gen-plist.sh t >/dev/null
P="$TMP/gen/local.herdr-sched-t.plist"
grep -A1 '<key>StartCalendarInterval</key>' "$P" | grep -q '<dict/>' && ! grep -q '<key>Hour</key>' "$P" \
  && { pass=$((pass + 1)); echo "ok   plist: 毎分起動(Hour/Minute を焼き込まない)"; } \
  || { failn=$((failn + 1)); echo "FAIL plist: 毎分起動になっていない"; }

# 間隔: 窓の始端から INTERVAL_MIN 刻みの回だけ実行する
check "間隔: 09:05 は実行(5 分刻み)"   sent             t "$THU 09:05" idle
check "間隔: 09:07 は刻みの外"          skipped_interval t "$THU 09:07" idle
NOW="$THU 09:07" bash bin/tick.sh t
ok_q() { [ ! -e "$LOG_DIR/t.log" ] && { pass=$((pass + 1)); echo "ok   $1"; } || { failn=$((failn + 1)); echo "FAIL $1"; }; }
ok_q "刻みの外は(DRY_RUN 以外でも)ログを書かない"
NOW="$THU 08:00" bash bin/tick.sh t; ok_q "窓の外は(DRY_RUN 以外でも)ログを書かない"

# START/END 形式と SCHED_* 上書き
cat >"$JOBS_DIR/se.conf" <<'C'
TARGET=dummy
PROMPT='do the thing'
START=10:00
END=12:00
INTERVAL_MIN=30
C
check "START/END 形式: 10:00 は実行"  sent           se "$THU 10:00" idle
check "START/END 形式: 12:30 は外"    skipped_window se "$THU 12:30" idle
export SCHED_START=08:00
check "SCHED_START 上書き: 08:00 は実行" sent         se "$THU 08:00" idle
check "SCHED_START 上書き: END は conf のまま" skipped_window se "$THU 12:30" idle
unset SCHED_START
export SCHED_WINDOW=13:00-14:00
check "SCHED_WINDOW 上書き: 13:30 は実行" sent        t "$THU 13:30" idle
check "SCHED_WINDOW 上書き: 09:00 は外"   skipped_window t "$THU 09:00" idle
unset SCHED_WINDOW
check "SCHED_INTERVAL_MIN=10: 09:10 は実行" sent t "$THU 09:10" idle
SCHED_INTERVAL_MIN=10 check "SCHED_INTERVAL_MIN=10: 09:05 は刻みの外" skipped_interval t "$THU 09:05" idle

# settings/<job>.settings(Web UI が書く上書き)
export SCHED_SETTINGS_DIR="$TMP/settings"; mkdir -p "$SCHED_SETTINGS_DIR"
printf 'INTERVAL_MIN=15\nSTART=10:00\nEND=11:00\nDAYS=weekdays\n' >"$SCHED_SETTINGS_DIR/t.settings"
check "settings: 間隔 15 分の 10:15 は実行"    sent             t "$THU 10:15" idle
check "settings: 10:05 は刻みの外"            skipped_interval t "$THU 10:05" idle
check "settings: 時間帯 10-11 の 09:00 は外"  skipped_window   t "$THU 09:00" idle
check "settings: weekdays の土曜は外"         skipped_window   t "2026-11-07 10:15" idle
SCHED_INTERVAL_MIN=30 check "SCHED_* は settings より優先" skipped_interval t "$THU 10:15" idle
printf 'ENABLED=0\n' >"$SCHED_SETTINGS_DIR/t.settings"
check "settings: ENABLED=0 は一時停止"        skipped_disabled t "$THU 09:00" idle
ok "show.sh: 実際に効く設定" "$(bash bin/show.sh t | jq -c '[.interval_min,.start,.end,.enabled,.overridden]')" '[5,"09:00","21:00",false,true]'
for bad in 'INTERVAL_MIN=5; rm -rf /' 'COMMAND=echo pwned' 'START=10:00' 'DAYS=$(id)' 'ENABLED=yes'; do
  printf '%s\n' "$bad" >"$SCHED_SETTINGS_DIR/t.settings"
  DRY_RUN=1 NOW="$THU 09:00" bash bin/tick.sh t >/dev/null 2>&1; ok "settings: 不正な行は拒否(exit 2): $bad" "$?" 2
done
ln -sf /etc/hostname "$SCHED_SETTINGS_DIR/sym.settings"; cp "$JOBS_DIR/t.conf" "$JOBS_DIR/sym.conf"
DRY_RUN=1 NOW="$THU 09:00" bash bin/tick.sh sym >/dev/null 2>&1; ok "settings: シンボリックリンクは拒否" "$?" 2
rm -rf "$SCHED_SETTINGS_DIR"; unset SCHED_SETTINGS_DIR

# ---- 秒単位
cat >"$JOBS_DIR/sec.conf" <<'C'
TARGET=dummy
PROMPT='do the thing'
WINDOW=09:00:30-09:02
INTERVAL_SEC=20
C
# check の先頭行だけでなく全行の action を見る
acts() { DRY_RUN=1 NOW="$2" FAKE_STATE=idle bash bin/tick.sh "$1" 2>&1 | jq -r '"\(.at[11:]) \(.action)"' | tr '\n' ' '; }
check "秒: 始端 09:00:30 は実行"             sent             sec "$THU 09:00:30" idle
check "秒: 09:00:50 は実行(20 秒刻み)"       sent             sec "$THU 09:00:50" idle
check "秒: 09:00:40 は刻みの外"              skipped_interval sec "$THU 09:00:40" idle
check "秒: 09:00:29 は窓の外"                skipped_window   sec "$THU 09:00:29" idle
check "秒: 終端 HH:MM はその分の 59 秒まで含む" sent           sec "$THU 09:02:50" idle
SCHED_WINDOW=09:00:30-09:02:10 check "秒: 終端を秒まで書けばその秒まで" skipped_window sec "$THU 09:02:30" idle
SCHED_WINDOW=09:00:30-09:02:10 check "秒: 終端ちょうどは実行"     sent           sec "$THU 09:02:10" idle
check "秒: 09:03:00 は窓の外"                skipped_window   sec "$THU 09:03:00" idle
ok "秒: 分指定の NOW はその分の回をすべて判定" "$(acts sec "$THU 09:01")" "09:01:10 sent 09:01:30 sent 09:01:50 sent "
ok "秒: 窓が分の途中から始まる"                "$(acts sec "$THU 09:00")" "09:00:30 sent 09:00:50 sent "
ok "分単位の既存ジョブは 1 分に 1 回だけ"       "$(acts t "$THU 09:05")" "09:05:00 sent "
ok "ログの at は秒まで"                       "$(acts t "$THU 09:05:00")" "09:05:00 sent "
ok "分単位ジョブを秒まで指定: 09:05:30 は刻みの外" "$(acts t "$THU 09:05:30")" "09:05:30 skipped_interval "
ok "show.sh: 秒の間隔は interval_min が null" "$(bash bin/show.sh sec | jq -c '[.interval_min,.interval_sec,.start,.end]')" '[null,20,"09:00:30","09:02"]'
ok "show.sh: 分の間隔は両方出る" "$(bash bin/show.sh t | jq -c '[.interval_min,.interval_sec]')" '[5,300]'
SCHED_INTERVAL_SEC=30 check "SCHED_INTERVAL_SEC=30: 09:00:30 は実行" sent t "$THU 09:00:30" idle
SCHED_INTERVAL_SEC=30 check "SCHED_INTERVAL_SEC は conf の INTERVAL_MIN より優先" skipped_interval t "$THU 09:00:20" idle
printf 'TARGET=dummy\nPROMPT=x\nWINDOW=09:00-10:00\nINTERVAL_MIN=1\nINTERVAL_SEC=30\n' >"$JOBS_DIR/both_iv.conf"
DRY_RUN=1 NOW="$THU 09:00" bash bin/tick.sh both_iv >/dev/null 2>&1; ok "INTERVAL_MIN と INTERVAL_SEC の同時指定はエラー" "$?" 2
for bad in "WINDOW=09:00-10:00 INTERVAL_SEC=0" "WINDOW=09:00:60-10:00 INTERVAL_SEC=5" "WINDOW=09:00:5-10:00 INTERVAL_SEC=5"; do
  printf 'TARGET=dummy\nPROMPT=x\n%s\n' $bad >"$JOBS_DIR/badsec.conf"
  DRY_RUN=1 NOW="$THU 09:00" bash bin/tick.sh badsec >/dev/null 2>&1; ok "不正な秒指定はエラー: $bad" "$?" 2
done
export SCHED_SETTINGS_DIR="$TMP/settings"; mkdir -p "$SCHED_SETTINGS_DIR"
printf 'INTERVAL_SEC=15\nSTART=10:00:00\nEND=10:00:45\n' >"$SCHED_SETTINGS_DIR/t.settings"
ok "settings: INTERVAL_SEC と HH:MM:SS" "$(acts t "$THU 10:00")" "10:00:00 sent 10:00:15 sent 10:00:30 sent 10:00:45 sent "
printf 'INTERVAL_MIN=1\nINTERVAL_SEC=15\n' >"$SCHED_SETTINGS_DIR/t.settings"
DRY_RUN=1 NOW="$THU 10:00" bash bin/tick.sh t >/dev/null 2>&1; ok "settings: INTERVAL_MIN と INTERVAL_SEC の同時指定は拒否" "$?" 2
printf 'INTERVAL_SEC=15\n' >"$SCHED_SETTINGS_DIR/t.settings"
ok "settings の INTERVAL_SEC は conf の INTERVAL_MIN を上書き" "$(acts t "$THU 09:00" | wc -w | tr -d ' ')" 8
rm -rf "$SCHED_SETTINGS_DIR"; unset SCHED_SETTINGS_DIR
mkcmd0() { printf "COMMAND='echo hi'\nWINDOW=00:00-23:59\nINTERVAL_SEC=%s\n" "$2" >"$JOBS_DIR/$1.conf"; }
mkcmd0 csec 30
NOW="$THU 12:00" bash bin/tick.sh csec
ok "COMMAND 型 30 秒刻み: 1 分で 2 回実行" "$(jq -r '"\(.at[11:]) \(.action)"' "$LOG_DIR/csec.log" | tr '\n' ' ')" "12:00:00 ran 12:00:30 ran "

# ---- COMMAND 型
mkcmd() { printf '%s\nWINDOW=%s\nINTERVAL_MIN=2\n' "$2" "${3:-00:00-23:59}" >"$JOBS_DIR/$1.conf"; }
mkcmd both "TARGET=dummy
COMMAND='echo hi'"
mkcmd cmd "COMMAND='echo out-line; echo err-line >&2; exit 3'"
mkcmd cmdok "COMMAND='echo ok'" 09:00-10:00
mkcmd slow "COMMAND='sleep 5'
COMMAND_TIMEOUT=1"
mkcmd long "COMMAND='head -c 2000 /dev/zero | tr \"\\\\0\" x'"
mkcmd lock "COMMAND='sleep 2'"
last() { tail -1 "$LOG_DIR/$1.log"; }
bash bin/tick.sh both >/dev/null 2>&1; ok "COMMAND と TARGET の同時指定はエラー(exit 2)" "$?" 2
check "COMMAND 型 DRY_RUN は実行せず ran" ran cmd "$THU 12:00"
check "COMMAND 型 窓の外は skipped_window" skipped_window cmdok "$THU 08:55"
check "COMMAND 型 終日 23:58 は実行(2 分刻み)" ran cmd "$THU 23:58"
NOW="$THU 12:00" bash bin/tick.sh cmd
ok "stdout/stderr/exit を記録" "$(last cmd | jq -r '[.action,.exit,.stdout,.stderr]|join("|")' | tr '\n' '~')" "failed|3|out-line|err-line~"
NOW="$THU 12:00" bash bin/tick.sh long
ok "出力は 500 字に切り詰め" "$(last long | jq -r '.stdout|length')" 500
t0=$SECONDS; NOW="$THU 12:00" bash bin/tick.sh slow
ok "タイムアウトで failed / exit 124" "$(last slow | jq -r '[.action,.exit]|join("|")')" "failed|124"
ok "タイムアウトは 4 秒以内に打ち切る" "$([ $((SECONDS - t0)) -le 4 ] && echo y)" y
NOW="$THU 12:00" bash bin/tick.sh lock & sleep 0.5
NOW="$THU 12:00" bash bin/tick.sh lock; wait
ok "多重実行は skipped_locked" "$(jq -r .action "$LOG_DIR/lock.log" | sort | tr '\n' ' ')" "ran skipped_locked "
ok "実行後にロックが残らない" "$([ -e "$LOG_DIR/lock.lock.d" ] && echo left || echo none)" none
mkdir "$LOG_DIR/cmd.lock.d"; echo 999999 >"$LOG_DIR/cmd.lock.d/pid"
NOW="$THU 12:00" bash bin/tick.sh cmd; ok "stale lock は回収して実行" "$(last cmd | jq -r .action)" failed

# ---- プロンプト送信は tb を通る(疑似 herdr と一時 DB。本物は呼ばない)
export FAKE_LOG="$TMP/herdr.log" TB_DB="$TMP/tb.db"; : >"$FAKE_LOG"
export FAKE_AGENTS='[{"pane_id":"wD:p1","name":"dummy","agent_status":"idle","agent_session":{"value":"sd"}}]'
NOW="2026-11-05 09:00" HERDR_BIN="$PWD/../taskboard/test/fake-herdr" bash bin/tick.sh t
ok "送信: tb 経由で sent" "$(last t | jq -r .action)" sent
ok "送信: 宛先にプロンプト" "$(grep -c $'^prompt dummy\tdo the thing' "$FAKE_LOG")" 1
ok "送信: messages に kind=scheduler" "$(sqlite3 "$TB_DB" "SELECT kind||':'||ref||':'||result FROM messages;")" "scheduler:job:t:sent"
unset FAKE_LOG TB_DB FAKE_AGENTS

echo "---- pass=$pass fail=$failn"
[ "$failn" = 0 ]

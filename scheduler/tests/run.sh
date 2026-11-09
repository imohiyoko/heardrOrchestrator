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

# gen-plist: エントリ数と境界
OUT_DIR="$TMP/gen" bash bin/gen-plist.sh t >/dev/null
P="$TMP/gen/local.herdr-sched-t.plist"
n=$(grep -c '<key>Hour</key>' "$P")
has() { grep -q "<key>Hour</key><integer>$1</integer><key>Minute</key><integer>$2</integer>" "$P"; }
[ "$n" = 145 ] && has 21 0 && has 9 0 && ! has 21 5 && ! has 8 55 \
  && { pass=$((pass + 1)); echo "ok   plist: 145 エントリ、09:00/21:00 を含み 08:55/21:05 を含まない"; } \
  || { failn=$((failn + 1)); echo "FAIL plist: entries=$n"; }

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
n=$(SCHED_INTERVAL_MIN=10 OUT_DIR="$TMP/gen2" bash bin/gen-plist.sh t | grep -o '[0-9]* entries')
[ "$n" = "73 entries" ] && { pass=$((pass + 1)); echo "ok   SCHED_INTERVAL_MIN=10 で 73 エントリ"; } \
  || { failn=$((failn + 1)); echo "FAIL SCHED_INTERVAL_MIN: $n"; }

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
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else failn=$((failn + 1)); echo "FAIL $1 want=[$3] got=[$2]"; fi; }
last() { tail -1 "$LOG_DIR/$1.log"; }
bash bin/tick.sh both >/dev/null 2>&1; ok "COMMAND と TARGET の同時指定はエラー(exit 2)" "$?" 2
check "COMMAND 型 DRY_RUN は実行せず ran" ran cmd "$THU 12:00"
check "COMMAND 型 窓の外は skipped_window" skipped_window cmdok "$THU 08:55"
check "COMMAND 型 終日 23:59 は実行" ran cmd "$THU 23:59"
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
n=$(OUT_DIR="$TMP/gen3" bash bin/gen-plist.sh cmd | grep -o '[0-9]* entries'); ok "終日 2 分刻みは 720 エントリ" "$n" "720 entries"

echo "---- pass=$pass fail=$failn"
[ "$failn" = 0 ]

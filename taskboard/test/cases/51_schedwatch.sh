# shellcheck shell=bash
# run.sh から番号順に source される。tb digest の scheduler 見張り(lib/schedwatch.sh)。
# fake な scheduler ディレクトリ(jobs / logs / settings)だけを読む。本物の scheduler・launchd には触れない。
# 現在時刻は TB_SCHEDWATCH_NOW で固定(1800000000 = 2027-01-15 17:00 JST、金曜)。
unset TB_IMMEDIATE_KINDS
export TB_DB=$TMP/schedwatch.db TB_CONFIG=$TMP/schedwatch.conf
: >"$TB_CONFIG"
: >"$FAKE_LOG"
ssql() { sqlite3 "$TB_DB" "$@"; }
export TB_SCHED_DIR=$TMP/sched TB_SCHEDWATCH_NOW=1800000000 TB_LIMIT_WATCHERS="watchx watchy"
export TB_SCHEDWATCH_CONF=$TMP/sched-watch.conf   # 無い → 既定値(disabled_min=30, watch_stale_min=20, 60 分で 5 回以上かつ 50%)
mkdir -p "$TB_SCHED_DIR/jobs" "$TB_SCHED_DIR/logs" "$TB_SCHED_DIR/settings"
NOW=$TB_SCHEDWATCH_NOW
# conf: <job> <ENABLED> <TARGET>
mkjob() {
  printf "ENABLED=%s\nTARGET=%s\nPROMPT='x'\nWINDOW=00:00-23:59\nINTERVAL_MIN=5\nDAYS=daily\nTZ=Asia/Tokyo\n" "$2" "$3" >"$TB_SCHED_DIR/jobs/$1.conf"
}
# ログ 1 行: <job> <何分前> <action>(ts は +0900 の形式で書く。tick.sh と同じ)
lg() { jq -nc --arg job "$1" --arg a "$3" --argjson e $((NOW - $2 * 60 + 32400)) \
         '{ts:($e|strftime("%Y-%m-%dT%H:%M:%S+0900")),job:$job,action:$a,reason:"t"}' >>"$TB_SCHED_DIR/logs/$1.log"; }
mkjob offlong 0 other;   for m in 40 35 30 25 20 15 10 5; do lg offlong $m skipped_disabled; done
mkjob offshort 0 other;  for m in 10 5; do lg offshort $m skipped_disabled; done
mkjob offsettings 1 other; printf 'ENABLED=0\n' >"$TB_SCHED_DIR/settings/offsettings.settings"; for m in 50 45; do lg offsettings $m skipped_disabled; done
mkjob watchstale 1 watchx; lg watchstale 45 ran; for m in 40 30 20 10 5; do lg watchstale $m skipped_busy; done
mkjob watchok 1 watchy;   lg watchok 5 ran
mkjob flaky 1 other;  for m in 55 50 45 40; do lg flaky $m ran; done; for m in 35 30 25 20 15 10; do lg flaky $m failed; done
mkjob fine 1 other;   for m in 55 50 45 40 35 30 25 20 15 10; do lg fine $m ran; done
mkjob onefail 1 other; lg onefail 5 failed       # 実行が 1 回しかない: 失敗率は見ない
fsum() { find "$TB_SCHED_DIR" -type f -exec cksum {} + | sort | cksum; }
before=$(fsum)
dry=$($TB digest --dry-run)
for want in "ジョブ offlong が ENABLED=0 のまま 40 分(skipped_disabled 8 回" "ジョブ offsettings が ENABLED=0 のまま" \
            "見張り系ジョブ watchstale の ran が 45 分無い" "ジョブ flaky の失敗が多い(直近 60 分で 10 回実行して failed 6 回 = 60%"; do
  [[ $dry == *"$want"* ]] && ok "schedwatch: dry-run has '$want'" || { ng "schedwatch: dry-run has '$want'"; echo "   actual: $dry"; }
done
for not in offshort watchok "ジョブ fine " onefail; do
  [[ $dry != *"$not"* ]] && ok "schedwatch: dry-run lacks '$not'" || { ng "schedwatch: dry-run lacks '$not'"; echo "   actual: $dry"; }
done
eq "schedwatch: read-only (scheduler files unchanged)" "$(fsum)" "$before"
eq "schedwatch: dry-run records nothing" "$(ssql "SELECT COUNT(*) FROM observations;")" "0"
out=$($TB digest); r=$?
eq "schedwatch: sent once" "$r|${out%% *}" "0|D-1"
eq "schedwatch: 4 observations recorded" "$(ssql "SELECT kind||'='||COUNT(*) FROM observations GROUP BY kind ORDER BY kind;" | tr '\n' ' ')" "schedfail=1 schedoff=2 schedstale=1 "
# 同じ状態のあいだは 2 回目を出さない
eq "schedwatch: unchanged state is not sent again" "$($TB digest)" "digest: 送るものはありません"
# 状態が変わる: watchstale が ran した → 記録が消える。offsettings を有効にする → 記録が消える
lg watchstale 1 ran; printf 'ENABLED=1\n' >"$TB_SCHED_DIR/settings/offsettings.settings"; lg offsettings 1 ran
eq "schedwatch: nothing to send after the change" "$($TB digest --dry-run)" "digest: 送るものはありません"
eq "schedwatch: cleared conditions drop their records" "$(ssql "SELECT kind||'='||COUNT(*) FROM observations GROUP BY kind ORDER BY kind;" | tr '\n' ' ')" "schedfail=1 schedoff=1 "
# また ran が無くなる(最後の ran が 30 分前になった)→ 新しい観測として、もう一度出る
: >"$TB_SCHED_DIR/logs/watchstale.log"; lg watchstale 30 ran; lg watchstale 10 skipped_busy
out=$($TB digest); eq "schedwatch: re-triggered state is sent again" "${out%% *}|$(ssql "SELECT COUNT(*) FROM observations WHERE kind='schedstale';")" "D-2|1"
[[ $($TB digest --dry-run) != *"watchstale"* ]] && ok "schedwatch: new state sent only once" || ng "schedwatch: new state sent only once"
# 設定で止める / しきい値を変える
eq "schedwatch: enabled=0 observes nothing" "$(TB_SCHEDWATCH_ENABLED=0 $TB digest --dry-run)" "digest: 送るものはありません"
ssql "DELETE FROM observations;"
d=$(TB_SCHEDWATCH_DISABLED_MIN=60 TB_SCHEDWATCH_WATCH_STALE_MIN=999 TB_SCHEDWATCH_FAIL_RATE_PCT=70 $TB digest --dry-run)
[[ $d == *offsettings* || $d == *offlong* || $d == *flaky* || $d == *watchstale* ]] && ng "schedwatch: thresholds raise the bar" || ok "schedwatch: thresholds raise the bar"
# 窓の外・曜日の外では「ran が無い」を出さない
ssql "DELETE FROM observations;"; printf 'WINDOW=10:00-12:00\n' >>"$TB_SCHED_DIR/jobs/watchstale.conf"
[[ $($TB digest --dry-run) != *"見張り系ジョブ watchstale"* ]] && ok "schedwatch: outside the window is not stale" || ng "schedwatch: outside the window is not stale"
eq "schedwatch: bad config value is refused" "$(TB_SCHEDWATCH_FAIL_RATE_PCT=abc rc $TB digest --dry-run)" "2"
unset TB_SCHED_DIR TB_SCHEDWATCH_NOW TB_LIMIT_WATCHERS TB_SCHEDWATCH_CONF

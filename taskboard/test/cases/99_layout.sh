# shellcheck shell=bash
# run.sh から番号順に source される(前のファイルが作った状態を使うものがある)
# --- 構成: コマンドと help の対応、herdr を呼ぶ場所
LIB=$HERE/../lib
cmds=$(grep -ohE '^cmd_[a-z-]+\(\)' "$LIB"/*.sh | sed 's/^cmd_//; s/()$//' | sort -u)
missing=""; for c in $cmds; do grep -qE "^tb $c( |$)" "$LIB/help.txt" || missing+=" $c"; done
eq "layout: every command is in help.txt" "$missing" ""
mkdir -p "$TMP/pathbin"; ln -sf "$(cd "$HERE/../bin" && pwd)/tb" "$TMP/pathbin/tb"
eq "layout: works through a symlink on PATH" "$("$TMP/pathbin/tb" help | head -1 | cut -c1-6)" "tb add"
eq "layout: unknown command → 2" "$(rc $TB no-such-command) $(rc $TB 'cmd_add')" "2 2"
eq "layout: only transport.sh runs herdr" "$(grep -lE '"\$HERDR_BIN"' "$LIB"/*.sh "$HERE/../bin/tb" | xargs -n1 basename | tr '\n' ' ')" "transport.sh "

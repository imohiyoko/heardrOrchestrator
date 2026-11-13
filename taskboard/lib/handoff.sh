# shellcheck shell=bash
# 他の人への調査依頼の文面づくり(handoff)。bin/tb から source される。単体では実行しない。
#
# - limits の human_handoff が on のときだけ。文面を data/handoff/<task-id>.md に書くだけで、何も送らない
#   (agent は誰にも連絡しない。貼る・送るのは人で、送り先も人が決める)
# - 書く前に、秘密らしい文字列(トークン、AWS のアクセスキー、秘密鍵のヘッダなど)が含まれていないか調べる。
#   含まれていれば書かずに 4 で終わる(タスクの題名・要約を直してから、もう一度)
# - 置き場所: 既定は taskboard/data/handoff(git 管理外)。TB_HANDOFF_DIR で変える

HANDOFF_DIR=${TB_HANDOFF_DIR:-$TB_ROOT/data/handoff}

# 秘密らしいものを探す。見つけたパターンの名前だけを stdout に出して 0(中身は出さない)。無ければ 1
handoff_secret_scan() {  # $1=本文
  local hit=1 name pat
  while IFS='|' read -r name pat; do
    if grep -Eiq -- "$pat" <<<"$1"; then echo "$name"; hit=0; fi
  done <<'P'
AWS アクセスキー|(AKIA|ASIA)[0-9A-Z]{16}
秘密鍵のヘッダ|-----BEGIN [A-Z ]*PRIVATE KEY-----
トークン(GitHub・Slack・API キーの形式)|(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,})
Bearer トークン|bearer +[A-Za-z0-9._~+/=-]{16,}
キー=値の形の秘密|(token|secret|passw(or)?d|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}
長い英数字の連なり(トークンの疑い)|[A-Za-z0-9]{32,}
P
  return $hit
}

cmd_handoff() {
  [[ $# -eq 1 ]] || usage "handoff <task-id>"
  valid_id "$1"
  local tid=$1 row title summary
  if [[ $(limit_get human_handoff) != on ]]; then
    echo "tb: handoff は使えません(human_handoff が off です。使うのは人が tb limits set human_handoff on)。何も書きません" >&2
    return 4
  fi
  row=$(require_task "$tid")
  title=$(jq -r '.title // ""' <<<"$row"); summary=$(jq -r '.summary // ""' <<<"$row")
  local text
  text=$(cat <<EOF
# 調査のお願い(人が貼る文面): $tid

> この文面は人が貼るためのものです。agent は誰にも連絡しません(送信も投稿もしません)。
> 送るかどうか、誰に・どこに送るかは人が決めます。貼る前に、秘密の値・リポジトリ名・組織名・顧客情報が
> 入っていないか確かめ、あれば <repo-A> のような仮名に置き換えてください。

## 目的
$title
${summary:-(要約はまだありません。人が書いてください)}

## 必要なアクセス
<必要なアクセスを人が書く(例: <repo-A> の読み取り)>

## 期限
<期限を人が決める>

## 成果物の返し先
<返し先を人が決める>
結果は人が受け取り、tb comment 相当で指揮官に戻します(本文はデータとして読まれます)。
EOF
)
  local hits
  if hits=$(handoff_secret_scan "$text"); then
    echo "tb: 文面に秘密らしい文字列が含まれるため、書きません(検出: $(tr '\n' ' ' <<<"$hits"))。" \
         "タスクの題名・要約から取り除いてから、もう一度 tb handoff $tid を実行してください(本文は表示しません)" >&2
    return 4
  fi
  local f=$HANDOFF_DIR/$tid.md
  [[ ! -e $f ]] || die "もう あります: $f(人が編集している可能性があるので上書きしません。消してからやり直してください)"
  mkdir -p "$HANDOFF_DIR"
  printf '%s\n' "$text" >"$f"
  echo "$f"
  echo "(人が内容を確かめて貼る文面です。tb は何も送っていません)"
}

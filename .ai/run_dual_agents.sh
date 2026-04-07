#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
AI_DIR="$ROOT/.ai"
mkdir -p "$AI_DIR"

# セッションごとのログディレクトリ
SESSION_TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$AI_DIR/logs/$SESSION_TS"
mkdir -p "$LOG_DIR"
# latest ポインタを更新 (symlink が使えない環境向けにファイルで代替)
echo "$LOG_DIR" > "$AI_DIR/logs/latest.txt"

CONFIG_FILE="$AI_DIR/agent.config"
REVIEW_SCHEMA="$AI_DIR/review.schema.json"
REVIEW_JSON="$AI_DIR/review.result.json"
REVIEW_FEEDBACK="$AI_DIR/review.feedback.txt"
SESSION_LOG="$LOG_DIR/session.log"

CLAUDE_WORKER_SESSION_ID=""
MAX_ROUNDS=3
RECONFIGURE=0

ROLE_MODE=""
WORKER_AGENT=""
REVIEWER_AGENT=""
CLAUDE_MODEL=""
CODEX_MODEL=""

# --- ログ関数 ---
log() {
  local msg="[$(date '+%H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$SESSION_LOG"
}

# Claude の stream-json 出力からツール使用・アシスタント応答をリアルタイム表示する
parse_claude_stream() {
  local label="$1"
  while IFS= read -r line; do
    # stream-json は1行ごとにJSON object
    local type
    type="$(echo "$line" | jq -r '.type // empty' 2>/dev/null)" || continue

    case "$type" in
      assistant)
        # アシスタントのテキスト応答
        local text
        text="$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text // empty' 2>/dev/null)"
        if [[ -n "$text" ]]; then
          echo "  [$label] $text"
        fi
        ;;
      result)
        # 最終結果テキスト
        local result_text
        result_text="$(echo "$line" | jq -r '.result // empty' 2>/dev/null)"
        if [[ -n "$result_text" ]]; then
          echo "  [$label] (result) $result_text"
        fi
        # サブツール利用数
        local stats
        stats="$(echo "$line" | jq -r '
          "turns=" + (.num_turns // 0 | tostring) +
          " input_tokens=" + (.total_input_tokens // 0 | tostring) +
          " output_tokens=" + (.total_output_tokens // 0 | tostring)
        ' 2>/dev/null)"
        if [[ -n "$stats" ]]; then
          echo "  [$label] (stats) $stats"
        fi
        ;;
    esac
  done
}

# Codex の JSONL 出力からイベントをリアルタイム表示する
parse_codex_stream() {
  local label="$1"
  while IFS= read -r line; do
    local type
    type="$(echo "$line" | jq -r '.type // empty' 2>/dev/null)" || continue

    case "$type" in
      message)
        local role content
        role="$(echo "$line" | jq -r '.role // empty' 2>/dev/null)"
        content="$(echo "$line" | jq -r '.content // empty' 2>/dev/null)"
        if [[ -n "$content" && "$content" != "null" ]]; then
          echo "  [$label][$role] $content" | head -c 500
          echo
        fi
        ;;
      function_call)
        local name
        name="$(echo "$line" | jq -r '.name // empty' 2>/dev/null)"
        if [[ -n "$name" ]]; then
          echo "  [$label] tool: $name"
        fi
        ;;
      function_call_output)
        local output
        output="$(echo "$line" | jq -r '.output // empty' 2>/dev/null | head -c 200)"
        if [[ -n "$output" ]]; then
          echo "  [$label] tool output: ${output}..."
        fi
        ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage:
  .ai/run_dual_agents.sh [--reconfigure] "your task"

Options:
  --reconfigure   初回設定をやり直す
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconfigure)
      RECONFIGURE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

TASK="$*"

if [[ ! -f "$REVIEW_SCHEMA" ]]; then
  echo "Missing $REVIEW_SCHEMA"
  exit 1
fi

derive_roles() {
  if [[ "$ROLE_MODE" == "claude_worker" ]]; then
    WORKER_AGENT="claude"
    REVIEWER_AGENT="codex"
  elif [[ "$ROLE_MODE" == "codex_worker" ]]; then
    WORKER_AGENT="codex"
    REVIEWER_AGENT="claude"
  else
    echo "Invalid ROLE_MODE: $ROLE_MODE" >&2
    exit 1
  fi
}

choose_from_menu() {
  local title="$1"
  shift
  local options=("$@")
  local choice

  printf '\n%s\n' "$title" >&2
  select choice in "${options[@]}"; do
    if [[ -n "${choice:-}" ]]; then
      printf '%s\n' "$choice"
      return 0
    fi
    printf '%s\n' "番号を選んでください。" >&2
  done
}

prompt_role_mode() {
  local selected
  selected="$(choose_from_menu \
    "役割を選択してください" \
    "Claude Code = 作業担当 / Codex = レビュー担当" \
    "Codex = 作業担当 / Claude Code = レビュー担当")"

  case "$selected" in
    "Claude Code = 作業担当 / Codex = レビュー担当")
      printf '%s\n' "claude_worker"
      ;;
    "Codex = 作業担当 / Claude Code = レビュー担当")
      printf '%s\n' "codex_worker"
      ;;
    *)
      echo "Invalid role selection." >&2
      exit 1
      ;;
  esac
}

prompt_claude_model() {
  local selected custom
  selected="$(choose_from_menu \
    "Claude Code のモデルを選択してください" \
    "sonnet" \
    "opus" \
    "手入力する")"

  if [[ "$selected" == "手入力する" ]]; then
    read -r -p "Claude Code のモデル名を入力してください: " custom
    if [[ -z "${custom// }" ]]; then
      echo "Claude model cannot be empty." >&2
      exit 1
    fi
    printf '%s\n' "$custom"
  else
    printf '%s\n' "$selected"
  fi
}

prompt_codex_model() {
  local selected custom
  selected="$(choose_from_menu \
    "Codex のモデルを選択してください" \
    "gpt-5.4" \
    "手入力する")"

  if [[ "$selected" == "手入力する" ]]; then
    read -r -p "Codex のモデル名を入力してください: " custom
    if [[ -z "${custom// }" ]]; then
      echo "Codex model cannot be empty." >&2
      exit 1
    fi
    printf '%s\n' "$custom"
  else
    printf '%s\n' "$selected"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
ROLE_MODE=$(printf '%q' "$ROLE_MODE")
CLAUDE_MODEL=$(printf '%q' "$CLAUDE_MODEL")
CODEX_MODEL=$(printf '%q' "$CODEX_MODEL")
EOF
}

load_or_init_config() {
  if [[ "$RECONFIGURE" -eq 1 || ! -f "$CONFIG_FILE" ]]; then
    echo "初回設定を行います。"
    ROLE_MODE="$(prompt_role_mode)"
    CLAUDE_MODEL="$(prompt_claude_model)"
    CODEX_MODEL="$(prompt_codex_model)"
    derive_roles
    save_config

    echo
    echo "保存しました: $CONFIG_FILE"
    echo "  Worker   : $WORKER_AGENT"
    echo "  Reviewer : $REVIEWER_AGENT"
    echo "  Claude   : $CLAUDE_MODEL"
    echo "  Codex    : $CODEX_MODEL"
  else
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    derive_roles
    echo "保存済み設定を使用します。"
    echo "  Worker   : $WORKER_AGENT"
    echo "  Reviewer : $REVIEWER_AGENT"
    echo "  Claude   : $CLAUDE_MODEL"
    echo "  Codex    : $CODEX_MODEL"
    echo "再設定したい場合は --reconfigure を付けてください。"
  fi
}

make_worker_prompt() {
  local round="$1"
  local prompt_file="$AI_DIR/worker.prompt.txt"

  if [[ "$round" == "1" ]]; then
    cat > "$prompt_file" <<EOF
You are the implementation agent.

Goal:
$TASK

Rules:
- Work only in the current repository.
- Make code changes directly.
- Run relevant tests, lint, and typecheck if available.
- Keep changes minimal and safe.
- Do not push remotely.
- Do not use web search or web fetch tools. Work only with local files.
- Stop only when the repository is in a reviewable state.
- At the end, provide a concise summary of what changed and what checks you ran.
EOF
  else
    cat > "$prompt_file" <<EOF
You are continuing the implementation task.

Original goal:
$TASK

Reviewer feedback to address:
$(cat "$REVIEW_FEEDBACK")

Rules:
- Fix every valid issue.
- Re-run relevant tests, lint, and typecheck if available.
- Keep changes minimal and safe.
- Do not push remotely.
- Do not use web search or web fetch tools. Work only with local files.
- Stop only when the repository is ready for re-review.
- At the end, provide a concise summary of what changed and what checks you ran.
EOF
  fi

  printf '%s' "$prompt_file"
}

build_review_context() {
  local round="$1"
  local context_file="$AI_DIR/review.context.txt"

  {
    echo "=== git status --short ==="
    git status --short || true
    echo
    echo "=== git diff --stat (unstaged) ==="
    git diff --stat || true
    echo
    echo "=== git diff --stat (staged) ==="
    git diff --cached --stat || true
    echo
    echo "=== git diff --unified=3 (unstaged) ==="
    git diff --unified=3 || true
    echo
    echo "=== git diff --cached --unified=3 (staged) ==="
    git diff --cached --unified=3 || true
    echo
    echo "=== Worker summary (round $round) ==="
    cat "$AI_DIR/worker.round${round}.txt" 2>/dev/null || echo "(no worker output)"
  } > "$context_file"

  printf '%s' "$context_file"
}

make_reviewer_prompt() {
  local round="$1"
  local context_file="$2"
  local prompt_file="$AI_DIR/reviewer.prompt.txt"

  cat > "$prompt_file" <<EOF
You are the review agent.

Original goal:
$TASK

Current round:
$round

Review requirements:
- Focus on correctness, regressions, edge cases, missing tests, security, maintainability, and type/build issues.
- Approve only when the current repository state is good enough to stop.
- If there are no meaningful issues, set approved to true.
- If there are issues, set approved to false and provide concrete, actionable fixes.
- Return ONLY valid JSON matching the provided schema.

Repository review context:
$(cat "$context_file")
EOF

  printf '%s' "$prompt_file"
}

run_worker_round_claude() {
  local round="$1"
  local prompt_file="$2"
  local raw_log="$LOG_DIR/worker.round${round}.stream.jsonl"

  # ワーカーに許可するツールを明示的に制限（--dangerously-skip-permissions の代替）
  local worker_tools="Read,Write,Edit,Bash,Glob,Grep,Agent"

  if [[ "$round" == "1" ]]; then
    CLAUDE_WORKER_SESSION_ID="$(uuidgen)"
    claude -p \
      --session-id "$CLAUDE_WORKER_SESSION_ID" \
      --model "$CLAUDE_MODEL" \
      --allowedTools "$worker_tools" \
      --verbose --output-format stream-json \
      --max-turns 50 \
      "$(cat "$prompt_file")" \
      | tee "$raw_log" \
      | parse_claude_stream "worker/claude" \
      || true
  else
    claude -p \
      --resume "$CLAUDE_WORKER_SESSION_ID" \
      --model "$CLAUDE_MODEL" \
      --allowedTools "$worker_tools" \
      --verbose --output-format stream-json \
      --max-turns 50 \
      "$(cat "$prompt_file")" \
      | tee "$raw_log" \
      | parse_claude_stream "worker/claude" \
      || true
  fi

  # stream-json の最終 result からテキストを抽出して保存
  # max_turns到達時はresultがnullになるため、最後のassistantメッセージからも抽出を試みる
  jq -r 'select(.type=="result") | .result // empty' "$raw_log" \
    > "$AI_DIR/worker.round${round}.txt" 2>/dev/null || true
  if [[ ! -s "$AI_DIR/worker.round${round}.txt" ]]; then
    jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text // empty' "$raw_log" \
      | tail -20 > "$AI_DIR/worker.round${round}.txt" 2>/dev/null || true
  fi
}

run_worker_round_codex() {
  local round="$1"
  local prompt_file="$2"
  local raw_log="$LOG_DIR/worker.round${round}.jsonl"

  codex exec \
    -m "$CODEX_MODEL" \
    --full-auto \
    --json \
    --output-last-message "$AI_DIR/worker.round${round}.txt" \
    "$(cat "$prompt_file")" \
    < /dev/null \
    2> "$LOG_DIR/worker.round${round}.stderr" \
    | tee "$raw_log" \
    | parse_codex_stream "worker/codex"
}

run_reviewer_round_codex() {
  local round="$1"
  local prompt_file="$2"
  local raw_log="$LOG_DIR/reviewer.round${round}.jsonl"

  codex exec \
    -m "$CODEX_MODEL" \
    -s read-only \
    --json \
    --output-schema "$REVIEW_SCHEMA" \
    --output-last-message "$REVIEW_JSON" \
    "$(cat "$prompt_file")" \
    < /dev/null \
    2> "$LOG_DIR/reviewer.round${round}.stderr" \
    | tee "$raw_log" \
    | parse_codex_stream "reviewer/codex"
}

run_reviewer_round_claude() {
  local round="$1"
  local prompt_file="$2"
  local schema_content
  local raw_log="$LOG_DIR/reviewer.round${round}.stream.jsonl"

  schema_content="$(cat "$REVIEW_SCHEMA")"

  claude -p \
    --model "$CLAUDE_MODEL" \
    --allowedTools "Read,Grep,Glob,Bash" \
    --verbose --output-format stream-json \
    --json-schema "$schema_content" \
    --max-turns 6 \
    "$(cat "$prompt_file")" \
    | tee "$raw_log" \
    | parse_claude_stream "reviewer/claude"

  # stream-json の最終 result から構造化出力を抽出
  # --json-schema 使用時は structured_output に格納される
  jq -r 'select(.type=="result") | .structured_output // .result // empty' "$raw_log" \
    > "$REVIEW_JSON" 2>/dev/null || true

  # structured_output はオブジェクトなので文字列化が必要な場合がある
  if jq -e 'type == "object"' "$REVIEW_JSON" >/dev/null 2>&1; then
    : # 既にJSON object — そのまま使用
  elif jq -e '. | fromjson' "$REVIEW_JSON" >/dev/null 2>&1; then
    jq -r '. | fromjson' "$REVIEW_JSON" > "$REVIEW_JSON.tmp" && mv "$REVIEW_JSON.tmp" "$REVIEW_JSON"
  fi

  cp "$REVIEW_JSON" "$LOG_DIR/reviewer.round${round}.json"
}

run_worker_round() {
  local round="$1"
  local prompt_file="$2"

  if [[ "$WORKER_AGENT" == "claude" ]]; then
    run_worker_round_claude "$round" "$prompt_file"
  else
    run_worker_round_codex "$round" "$prompt_file"
  fi
}

run_reviewer_round() {
  local round="$1"
  local prompt_file="$2"

  if [[ "$REVIEWER_AGENT" == "codex" ]]; then
    run_reviewer_round_codex "$round" "$prompt_file"
  else
    run_reviewer_round_claude "$round" "$prompt_file"
  fi
}

load_or_init_config

log "Session started: task='$TASK'"
log "Logs: $LOG_DIR"

for round in $(seq 1 "$MAX_ROUNDS"); do
  log "===== ROUND $round / $MAX_ROUNDS ====="

  log "--- Worker ($WORKER_AGENT) starting ---"
  WORKER_PROMPT_FILE="$(make_worker_prompt "$round")"
  cp "$WORKER_PROMPT_FILE" "$LOG_DIR/worker.round${round}.prompt.txt"
  run_worker_round "$round" "$WORKER_PROMPT_FILE"
  log "--- Worker ($WORKER_AGENT) finished ---"

  log "--- Reviewer ($REVIEWER_AGENT) starting ---"
  REVIEW_CONTEXT_FILE="$(build_review_context "$round")"
  cp "$REVIEW_CONTEXT_FILE" "$LOG_DIR/review.round${round}.context.txt"
  REVIEWER_PROMPT_FILE="$(make_reviewer_prompt "$round" "$REVIEW_CONTEXT_FILE")"
  cp "$REVIEWER_PROMPT_FILE" "$LOG_DIR/reviewer.round${round}.prompt.txt"
  run_reviewer_round "$round" "$REVIEWER_PROMPT_FILE"
  log "--- Reviewer ($REVIEWER_AGENT) finished ---"

  if ! jq . "$REVIEW_JSON" >/dev/null 2>&1; then
    log "ERROR: Reviewer output is not valid JSON: $REVIEW_JSON"
    exit 1
  fi

  # レビュー結果のサマリーをログに出力
  log "Review summary: $(jq -r '.summary // "(no summary)"' "$REVIEW_JSON")"

  if jq -e '.approved == true' "$REVIEW_JSON" >/dev/null; then
    log "Approved by reviewer on round $round"
    exit 0
  fi

  jq -r '
    "Summary: " + .summary + "\n\nIssues:\n" +
    (
      .issues
      | map("- [" + .severity + "] " + .title + " (" + .file + ":" + ((.line // 0)|tostring) + ")\n  " + .details + "\n  Suggested fix: " + .suggested_fix)
      | join("\n\n")
    )
  ' "$REVIEW_JSON" > "$REVIEW_FEEDBACK"

  cp "$REVIEW_FEEDBACK" "$LOG_DIR/review.round${round}.feedback.txt"
  log "Reviewer requested changes. See: $LOG_DIR/review.round${round}.feedback.txt"
done

log "Reviewer did not approve within $MAX_ROUNDS rounds."
exit 1
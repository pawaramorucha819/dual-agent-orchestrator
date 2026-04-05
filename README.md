# Dual Agent Orchestrator

Claude Code と OpenAI Codex を組み合わせ、**作業エージェント（Worker）** と **レビューエージェント（Reviewer）** の2役に分けてタスクを遂行するシェルベースのオーケストレーションツールです。

## 概要

1つのタスクに対して、Worker がコード変更を行い、Reviewer が構造化された JSON 形式でレビューを返す——このサイクルを最大3ラウンド繰り返し、Reviewer が承認するまで自動的に改善を続けます。

```
┌─────────┐     コード変更      ┌──────────┐
│  Worker  │ ──────────────────> │ Reviewer  │
│ (実装)   │ <────────────────── │ (レビュー) │
└─────────┘   フィードバック     └──────────┘
       ↑                              │
       └──── 承認されるまで繰り返し ────┘
```

## クイックスタート

```bash
# 1. リポジトリをクローン
git clone https://github.com/pawaramorucha819/dual-agent-orchestrator.git
cd dual-agent-orchestrator

# 2. 実行権限を付与
chmod +x .ai/run_dual_agents.sh

# 3. 実行（初回は対話形式で役割・モデルを設定）
.ai/run_dual_agents.sh "TODOアプリにバリデーションを追加する"
```

初回実行時に Worker / Reviewer の役割分担とモデルを選択するプロンプトが表示されます。設定は `.ai/agent.config` に保存され、次回以降は自動で再利用されます。

## 必要なもの

- **Bash** (4.0+)
- **jq**
- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** (`claude`)
- **[OpenAI Codex CLI](https://github.com/openai/codex)** (`codex`)
- **uuidgen**
- 各 CLI にログイン済みであること
- **git リポジトリ**内で実行すること（スクリプトは `git rev-parse --show-toplevel` でルートを検出します）

## 使い方

```bash
# 基本実行
.ai/run_dual_agents.sh "ログイン機能にレート制限を追加する"

# 設定をやり直す場合
.ai/run_dual_agents.sh --reconfigure "バグを修正する"
```

### 初回設定

初回実行時に対話形式で以下を選択します（設定は `.ai/agent.config` に保存されます）。

| 設定項目 | 内容 |
|---------|------|
| 役割分担 | Claude Code を Worker にするか、Codex を Worker にするか |
| Claude モデル | `sonnet`, `opus`, `opus[1m]` など任意のモデル名 |
| Codex モデル | `gpt-5.4`, `gpt-5.3-codex` など任意のモデル名 |

## ディレクトリ構成

```
.ai/
├── run_dual_agents.sh        # メインのオーケストレーションスクリプト
├── review.schema.json        # レビュー結果の JSON Schema
├── agent.config              # 保存された設定（自動生成）
├── worker.prompt.txt         # 最新の Worker プロンプト（自動生成）
├── reviewer.prompt.txt       # 最新の Reviewer プロンプト（自動生成）
├── review.context.txt        # Reviewer に渡すリポジトリ状態（自動生成）
├── review.result.json        # 最新のレビュー結果 JSON（自動生成）
├── review.feedback.txt       # Worker に渡すフィードバック（自動生成）
├── worker.round*.txt         # 各ラウンドの Worker 出力（自動生成）
└── logs/                     # セッションごとの詳細ログ（自動生成）
    └── YYYYMMDD_HHMMSS/
        ├── session.log
        ├── worker.round*.prompt.txt
        ├── worker.round*.stream.jsonl
        ├── reviewer.round*.prompt.txt
        ├── reviewer.round*.stream.jsonl
        └── reviewer.round*.json
```

### .gitignore の推奨

自動生成ファイルをリポジトリに含めないよう、以下を `.gitignore` に追加することを推奨します。

```gitignore
# Dual Agent Orchestrator の自動生成ファイル
.ai/agent.config
.ai/logs/
.ai/*.txt
.ai/*.json
!.ai/review.schema.json
```

## レビュー結果のスキーマ

Reviewer は以下の構造の JSON を返します。

```json
{
  "approved": false,
  "summary": "レビューの要約",
  "issues": [
    {
      "severity": "critical | high | medium | low",
      "title": "問題のタイトル",
      "file": "対象ファイル",
      "line": 42,
      "details": "問題の詳細",
      "suggested_fix": "修正案"
    }
  ]
}
```

`approved` が `true` になるとオーケストレーションは成功終了します。最大ラウンド数（デフォルト: 3）以内に承認されなかった場合はエラー終了します。

## ライセンス

このプロジェクトは [MIT License](LICENSE) の下で公開されています。

ただし、本プロジェクトが利用する以下の外部ツールはこのライセンスの範囲外です。各ツールの利用規約に従ってください。

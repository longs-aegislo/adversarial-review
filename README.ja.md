[English](README.md) | [中文](README.zh.md) | **日本語**

# Adversarial Review（敵対的コードレビュー）

Claude と GPT Codex による敵対的ディベートループを用いた
マルチエージェント・コードレビューツールです。

[asimov-ralph](https://github.com/frankbria/ralph-claude-code) のパターンと
[AI Debate](https://arxiv.org/abs/2410.04663) に関する研究をベースにしています。

## コンセプト

Claude と Codex が対象プロジェクトを個別にレビューし、互いの指摘を検証し、
不一致を調整した上で、選択された修正エージェントが合意済みの変更を実装します。

ループは次の4フェーズで構成されます：

1. 独立レビュー
2. クロスレビュー
3. メタレビューと合意形成
4. 統合と実装

各指摘には `IN_SCOPE` または `PRE_EXISTING` が付きます。フェーズ4は
デフォルトで `IN_SCOPE` のみを修正し、既存問題は別途報告します。
両カテゴリを意図的に修正する場合だけ `--include-pre-existing` を指定します。

フェーズ1〜3ではエージェント権限が読み取り専用になり、書き込み権限を得るのは
フェーズ4で選択された修正エージェントだけです。`--prompt FILE` はその実行に
限ってフェーズ1のレビュー基準を追加し、必須の Issue・Scope・Status
プロトコルを置き換えません。

## クイックスタート

```bash
cd adversarial-review

# プロジェクトをレビュー
./adversarial_review.sh ../my-project

# 指定した Git ref 以降の変更だけをレビュー
./adversarial_review.sh --base main ../my-project

# フェーズ4の修正エージェントを選択
./adversarial_review.sh --fixer codex ../my-project

# 今回の実行にレビュー基準を追加
./adversarial_review.sh --prompt security-review.md ../my-project

# APIを呼ばず、スコープとフェーズ4ポリシーを確認
./adversarial_review.sh --dry-run --base main ../my-project
```

## 必要要件

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）または `apt install jq`（Linux）
- **coreutils**（macOSのみ、timeout用）：`brew install coreutils`

## ドキュメント

- [詳細ガイド](docs/guide.ja.md) — CLI全体、レビューフェーズ、状態管理、
  成果物、カスタマイズ、コストに関する説明
- [Fork変更履歴](docs/fork-notes.ja.md) — アップストリームとの差分と修正
- [ドメイン用語集](CONTEXT.md) — 実装で使用する共通用語
- [ツール比較評価](docs/evaluations/tool-bakeoff/README.md) — Chorus、
  Open Code Review、coding-review-agent-loop との比較、再現可能な fixture と
  生の検証記録

## コントリビューション

これは実験的なプロトタイプです。レビューエージェントの追加、精度に基づく投票、
コスト制御、成果物の可視化などを改善できます。

## ライセンス

MIT

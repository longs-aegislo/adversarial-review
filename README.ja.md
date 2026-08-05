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

各指摘には `IN_SCOPE` または `PRE_EXISTING` が付きます。apply-fixes モードでは、
フェーズ4はデフォルトで `IN_SCOPE` のみを修正し、既存問題は別途報告します。
両カテゴリを意図的に修正する場合だけ `--include-pre-existing` を指定します。

フェーズ1〜3ではエージェント権限が読み取り専用になります。apply-fixes モード
だけが、フェーズ4で選択された修正エージェントに書き込み権限を与えます。
`--prompt FILE` はその実行に限ってフェーズ1のレビュー基準を追加し、必須の
Issue・Scope・Status プロトコルを置き換えません。

`--review-only` または `--apply-fixes` を指定すると、今回の実行でフェーズ4に
読み取り専用の統合を行うか、書き込み権限を与えて修正を適用するかを明示できます。
review-only モードでも4フェーズすべてを実行し、フェーズ4はフェーズ1〜3と同じ
読み取り専用 Backend 境界を使います。Target Repo を変更せず、未解決の
`IN_SCOPE` と `PRE_EXISTING` の指摘を分けて報告します。両者は互いに排他的で、
依存関係チェックやエージェント呼び出しの前に検証されます。両方とも省略した
場合は、現在の暗黙的な apply-fixes の挙動を維持し、移行警告を表示します。
新しく追加する自動化・Skill・Plugin は、いずれかを明示的に指定してください。

各実行では、2つのレビュースロットと対象ディレクトリを
`slot-a slot-b target-dir` の順で明示する必要があります。3つとも長形式の
オプションでも指定できます。各スロットは `claude` または `codex` を受け付け、
同じバックエンドを2つに指定した場合も実行できますが、多様性低下の警告が出ます。

## クイックスタート

```bash
cd adversarial-review

# プロジェクトをレビュー
./adversarial_review.sh claude codex ../my-project

# 指定した Git ref 以降の変更だけをレビュー
./adversarial_review.sh --base main claude codex ../my-project

# フェーズ4の修正エージェントを選択
./adversarial_review.sh --fixer codex claude codex ../my-project

# 今回の実行にレビュー基準を追加
./adversarial_review.sh --prompt security-review.md claude codex ../my-project

# CI や自動化向けに JSON 結果をアトミック出力
./adversarial_review.sh --apply-fixes --result-file review-result.json claude codex ../my-project

# APIを呼ばず、スコープとフェーズ4ポリシーを確認
./adversarial_review.sh --dry-run --base main --slot-a claude --slot-b codex --target-dir ../my-project
```

## 自動化契約

| モード | Agent 呼び出し | Target への書き込み | 完了後も finding が残る場合 |
| --- | --- | --- | ---: |
| `--review-only` | 4フェーズすべて | なし | `10` |
| `--apply-fixes` | レビューと許可された修正／検証 | フェーズ4で可能 | `11` |
| 両方省略（従来動作） | `--apply-fixes` と同じ | フェーズ4で可能 | `11` |

従来の暗黙モードは移行警告を表示し、将来削除される可能性があります。新しい自動化は
必ずモードを明示してください。`--dry-run` はプレビュー専用で、Agent を呼び出さず
レビュー結論も生成しないため、`--review-only` の代わりにはなりません。

安定した終了ステータスは `0` clean、`10` review-only findings、`11` apply-fixes
findings、`12` incomplete review、`64` invalid invocation、`70` Agent/Backend
failure、`77` write-boundary violation です。完全なバージョン付き JSON 結果には
`--result-file PATH` を追加してください。[結果ファイル契約](docs/result-file.ja.md)に
全フィールド、オブジェクト例、外側の LLM/Skill 向けルーティング指針があります。

## 必要要件

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）または `apt install jq`（Linux）
- **coreutils**（macOSのみ、timeout用）：`brew install coreutils`

## ドキュメント

- [リポジトリ単位の Adversarial Review Skill](.agents/skills/adversarial-review/SKILL.md) —
  明示呼び出しで既定は review-only。明確な review-and-fix 要求と Fixer 指定がある場合のみ修正します。CLI、backend、認証、依存関係を
  読み取り専用で事前確認し、baseline に基づくファイル scope を Agent 実行前に
  安全に baseline を推定または受け取り、保護されたファイル scope をプレビューして、
  バージョン付き機械結果を厳密に検証し、clean、findings、未完了、ポリシー違反、
  インフラ障害を別々の実行可能な説明として示します
- [詳細ガイド](docs/guide.ja.md) — CLI全体、レビューフェーズ、状態管理、
  成果物、カスタマイズ、コストに関する説明
- [プロセス終了ステータス](docs/exit-statuses.ja.md) — CI と自動化向けの安定した契約
- [機械可読結果ファイル](docs/result-file.ja.md) — 全終了経路を扱うバージョン付きアトミック JSON
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

[English](fork-notes.md) | [中文](fork-notes.zh.md) | **日本語**

# Fork 変更履歴

[README に戻る](../README.ja.md) · [詳細ガイド](guide.ja.md)

本リポジトリは
[alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review)
（`upstream` remote として保持）からのフォークです。実際の Laravel
プロジェクトでツールを動かして見つかった問題を修正しており、
アップストリームとの主な差分は以下の通りです：

- **`codex` の呼び出し方法を修正**：従来の `run_codex()` は現在の CLI と一致しない古い構文（`-q --full-auto --prompt`）を使用していました。現在は `codex exec -s <sandbox_mode> --skip-git-repo-check` を使い、prompt を stdin 経由で渡して、大きな prompt による `ARG_MAX` エラーを回避します。
- **JS/Python 以外のスタックに対するソース収集を修正**：`vendor/`、`public/`、`storage/`、`bootstrap/cache/`、`dist/`、`build/` を除外し、PHP/Blade を扱えるようにしました。
- **フェーズ3で相手の指摘が失われる問題を修正**：メタレビューに両者のフェーズ1レビューと自分のフェーズ2クロスレビューを再提供し、ステートレスな CLI 呼び出しの間で指摘が消えないようにしました。
- **`parse_status_block` の最後のブロック抽出を修正**：prompt 内の例を含むすべての状態ブロックを連結せず、awk で最後の本物のブロックだけを保持します。
- **`-f/--fixer` を追加**：フェーズ4の修正を Claude と Codex のどちらに任せるか選択できます。
- **指摘のスコープゲートを追加**：各指摘に `IN_SCOPE` または `PRE_EXISTING` を付与し、メタレビューで不一致を調整します。フェーズ4はデフォルトで対象範囲内だけを修正し、`--include-pre-existing` で既存問題も明示的に含められます。
- **フェーズ1で完全なファイル内容を埋め込まないよう変更**：エージェントはファイルパス一覧（2回目以降は `HEAD` に対する `git diff` も付与）を受け取り、必要なファイルを自分で読みます。
- **各フェーズの要約をターミナル出力に追加**：問題数だけでなく、一行要約も表示します。
- **すべての状態をターゲットディレクトリごとに分離**：`tracking.json`、サーキットブレーカー、`artifacts/` は安定した user state root（`${XDG_STATE_HOME:-$HOME/.local/state}/adversarial-review/<slug>/`、または `AR_STATE_ROOT`）以下に保存され、project や versioned Plugin install の間で混ざったり失われたりしません。
- **フェーズ2/3が誤ったディレクトリで実行される問題を修正**：正しい `target_dir` を渡し、Claude には読み取り／検索に加えてスコープ判定用の読み取り専用 `git log`/`git blame` を許可します。
- **`collect_recent_diff()` の未追跡ファイル処理を修正**：ソース収集と同じ除外規則を適用し、秘密情報らしいファイル名、バイナリ、大容量の内容を prompt に入れません。
- **誤解を招く diff ラベルを修正**：表示内容が前回のイテレーション以降ではなく、実行全体で累積した未コミット diff であることを明記しました。
- **エージェント間の指摘 ID 衝突を修正**：各 ID にエージェントタグ（`CLAUDE-1`、`CODEX-1` など）を付けます。
- **フェーズ2の追加指摘が統合から落ちる問題を修正**：`{エージェント}-ADD-N` 形式で追跡し、フェーズ1の指摘と同じ ledger に含めます。

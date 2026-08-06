# 機械可読結果ファイル

`--result-file <パス>` を指定すると、各呼び出しはそのパスを1つの完全な JSON
オブジェクトでアトミックに置き換えます。引数解析が実際にこのオプションへ到達
した時点で出力先が有効になり、それ以降は正常終了でも任意の失敗経路でも結果を
生成します。既存のターミナル出力は変わりません。

Git ワークツリーでは、`target_changes.files` は追跡済みファイルと無視対象外の
未追跡ファイルを扱い、Git の無視対象ファイルは除外します。
`target_repo.identity` と `target_repo.remote_url` から URL のユーザー情報を
除去するため、リモート URL に埋め込まれた認証情報は結果へ保存されません。

```bash
./adversarial_review.sh --apply-fixes --result-file review-result.json \
  claude codex ../my-project
```

出力先と同じディレクトリに一時ファイルを作り、完全なオブジェクトを書き終えて
から rename します。読み手が観測するのは以前の完全な結果か新しい完全な結果だけで、
途中までの JSON は見えません。

## スキーマバージョン 1

公開スキーマの全フィールドを以下に示します。値を取得できない場合、または対応する
フェーズが未実行の場合、nullable な文字列は JSON `null` になります。

- `schema_version`（整数）：現在は `1`。
- `target_repo`（オブジェクト）：`identity`（利用可能ならリモート URL、そうでなければ
  Target の絶対パス）、`path`（Target の絶対パス）、nullable な `git_root`、
  認証情報を除去した nullable な `remote_url`、実行開始時の nullable な
  `head_commit`。
- `reviewers`（オブジェクト）：解決済み Backend の nullable な `slot_a` と `slot_b`。
- `synthesis`（オブジェクト）：nullable な `requested_fixer` と `executed_by`。
  後者は実際にフェーズ4を実行した Agent です。
- `scope`（オブジェクト）：`kind`（`whole-directory` または `base`）、nullable な
  `requested_base_ref` と `resolved_base_commit`。
- `execution`（オブジェクト）：`mode`（`review-only` または `apply-fixes`）、真偽値の
  `dry_run`、`review_executed`、`include_pre_existing`。
- `termination`（オブジェクト）：安定した `category`、より具体的な `reason`、数値の
  `exit_code`。分類は[終了ステータス契約](exit-statuses.ja.md)と一致します。
- `iterations`（整数）：この呼び出しが開始したイテレーション数。
- `counts.findings`（オブジェクト）：一意な `in_scope`、`pre_existing` finding 数と
  `scope_conflicts`。scope の不一致は保守的に後者2つの両方へ含めます。
- `counts.fixes`（オブジェクト）：`in_scope` と `pre_existing` の修正数。
- `counts.pre_existing_flagged`（整数）：Synthesis が報告したが修正しなかった既存
  finding 数。
- `target_changes`（オブジェクト）：真偽値の `modified` と、Target からの相対パスで
  変更・作成・削除ファイルを列挙する `files`。
- `paths`（オブジェクト）：`state_dir`、`artifacts_dir`、nullable な
  `final_synthesis_artifact` の各パス。

例（パス、commit ID、件数は説明用です）：

```json
{
  "schema_version": 1,
  "target_repo": {
    "identity": "https://github.com/example/shop.git",
    "path": "/work/shop",
    "git_root": "/work/shop",
    "remote_url": "https://github.com/example/shop.git",
    "head_commit": "0123456789abcdef0123456789abcdef01234567"
  },
  "reviewers": { "slot_a": "claude", "slot_b": "codex" },
  "synthesis": { "requested_fixer": "codex", "executed_by": "codex" },
  "scope": {
    "kind": "base",
    "requested_base_ref": "main",
    "resolved_base_commit": "fedcba9876543210fedcba9876543210fedcba98"
  },
  "execution": {
    "mode": "review-only",
    "dry_run": false,
    "review_executed": true,
    "include_pre_existing": false
  },
  "termination": {
    "category": "review-only-findings-remain",
    "reason": "review-only-findings-remain",
    "exit_code": 10
  },
  "iterations": 1,
  "counts": {
    "findings": { "in_scope": 2, "pre_existing": 1, "scope_conflicts": 0 },
    "fixes": { "in_scope": 0, "pre_existing": 0 },
    "pre_existing_flagged": 1
  },
  "target_changes": { "modified": false, "files": [] },
  "paths": {
    "state_dir": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4",
    "artifacts_dir": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4/artifacts",
    "final_synthesis_artifact": "/home/user/.local/state/adversarial-review/shop-a1b2c3d4/artifacts/iter1_4_synthesis.md"
  }
}
```

`--dry-run` は選択した実行モードを保ちつつ、`dry_run` を `true`、
`review_executed` を `false`、`synthesis.executed_by` を `null` にします。
通常の最大イテレーション結果は `incomplete-review` のままで、実レビュー完了と
誤解されません。
`--review-only` とは異なり、dry-run は Agent を呼び出さず、レビュー結論も生成
しないため、読み取り専用レビューの代わりにはなりません。

## 外側の LLM / Skill から結果を利用する

オーケストレーションを行う LLM/Skill はターミナルテキストではなく JSON
フィールドを読み取ります。例えば `execution.review_executed` が false ならレビュー
未実行と報告します。`termination.category` が `review-only-findings-remain` なら
`paths.final_synthesis_artifact` を開き、新しい明示的な `--apply-fixes` 実行を開始
するか人に確認します。`clean` ならリリースを続行します。その他の分類は停止または
失敗として `termination.reason` を提示します。JSON ファイルが存在するだけで成功と
判断してはいけません。

値は人間向けワークフローと同じ解析済み status block、tracking state、CLI の
解決済み設定、Target スナップショットに由来します。ターミナルテキストを再解析
することはありません。

出力先をアトミックに置き換えられない場合（パスがディレクトリを指す場合など）は、
レビュー自体の終了コードを維持し、stderr に明示的なエラーを出します。永続化の
失敗を黙って無視することはありません。

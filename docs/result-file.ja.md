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

トップレベルオブジェクトには次が含まれます。

- `schema_version`: 現在は `1`。
- `target_repo`: Target Repo の識別子、絶対パス、Git ルート、`origin` URL、
  取得可能な場合は実行開始時の `HEAD` commit。
- `reviewers`: 解決済みの `slot_a`、`slot_b` Backend 割り当て。
- `synthesis`: 要求された fixer と、実際にフェーズ4を実行した Agent。
  フェーズ4未実行時の `executed_by` は `null`。
- `scope`: `whole-directory` または `base`、要求した base ref と解決済み commit。
- `execution`: `review-only`/`apply-fixes`、`dry_run`、レビュー Agent が実際に
  実行されたか、pre-existing finding ポリシー。
- `termination`: 安定した終了分類、より具体的な理由、数値の終了コード。
  分類は[終了ステータス契約](exit-statuses.ja.md)と一致します。
- `iterations`: この呼び出しが開始したイテレーション数。
- `counts`: 解析済み status ledger にある一意な `IN_SCOPE`/`PRE_EXISTING` finding
  数、scope 衝突数、解析済み Synthesis status にある修正数・既存問題の報告数。
  reviewer ledger 間で scope が一致しない場合は保守的に `PRE_EXISTING` として数え、
  `scope_conflicts` にも含めます。
- `target_changes`: 呼び出しが Target を変更したか、および変更・作成・削除した
  相対ファイルパス。
- `paths`: state ディレクトリ、Artifact ディレクトリ、存在する場合は最終
  Synthesis Artifact。

`--dry-run` は選択した実行モードを保ちつつ、`dry_run` を `true`、
`review_executed` を `false`、`synthesis.executed_by` を `null` にします。
通常の最大イテレーション結果は `incomplete-review` のままで、実レビュー完了と
誤解されません。

値は人間向けワークフローと同じ解析済み status block、tracking state、CLI の
解決済み設定、Target スナップショットに由来します。ターミナルテキストを再解析
することはありません。

出力先をアトミックに置き換えられない場合（パスがディレクトリを指す場合など）は、
レビュー自体の終了コードを維持し、stderr に明示的なエラーを出します。永続化の
失敗を黙って無視することはありません。

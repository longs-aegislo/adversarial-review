# プロセス終了ステータス

`adversarial_review.sh` は、次の安定したプロセス終了ステータスを公開します。
呼び出し側は内部リファクタリング後もこれらの値に依存できます。内部のフェーズと
Backend 戻り値はプロセス終了前にこの公開契約へ変換され、意図的に外部
インターフェースには含まれません。

| ステータス | 名前 | 意味 |
| ---: | --- | --- |
| `0` | clean | レビューが完了し、findings が残っていません。Phase 1 での clean と synthesis 後の clean の両方を含みます。管理コマンドの成功も引き続き `0` です。 |
| `10` | review-only-findings | `--review-only` が synthesis を完了し、1 件以上の未解決 findings を報告しました。 |
| `11` | apply-fixes-findings | `--apply-fixes` が許可された修正を完了しましたが、未解決または pre-existing として報告された findings が残っています。 |
| `12` | incomplete-review | `--max-iters` 到達または circuit breaker の OPEN によりレビューが未完了です。ログと `tracking.json` の `max_iterations` / `circuit_open` で理由を区別できます。 |
| `64` | invalid-invocation | 引数の競合、無効な base ref、必須入力の欠落などにより、Agent 呼び出し前に実行が拒否されました。 |
| `70` | agent-backend-failure | 必要な Agent/backend が利用不能、失敗、タイムアウト、または必須レスポンスが不正でした。 |
| `77` | write-boundary-violation | 読み取り専用 Agent が拒否される書き込みを試みたか、読み取り専用フェーズ中に Target が変更されました。 |

`--review-only` と `--apply-fixes` は同じ契約を共有します。完了後に findings が
残る場合だけ `10` と `11` を分け、変更がすでに適用された可能性を自動化から
判定できるようにしています。`--status`、`--reset`、`--circuit-status`、
`--reset-circuit` は従来のコマンド意味論を維持します。

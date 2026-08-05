[English](guide.md) | [中文](guide.zh.md) | **日本語**

# Adversarial Review 詳細ガイド

[README に戻る](../README.ja.md) · [Fork 変更履歴](fork-notes.ja.md)

Claude と GPT Codex による敵対的ディベートループを用いたマルチエージェント・コードレビューツールです。

[asimov-ralph](https://github.com/frankbria/ralph-claude-code) のパターンと [AI Debate](https://arxiv.org/abs/2410.04663) に関する研究をベースにしています。

## このフォークについて

このフォークのアップストリームとの差分は、
[Fork 変更履歴](fork-notes.ja.md)で個別に管理しています。

## コンセプト

Claude または Codex を割り当てられる2つのレビュースロットが、それぞれ独立して
コードをレビューし、複数ラウンドのディベートで互いの指摘を批評します。両スロットは
異なるバックエンドにも同じバックエンドにもできます。この敵対的なプロセスには次の利点があります：

- **より多くの問題を発見**：異なるモデルは異なる問題を見つけます
- **誤検知の排除**：クロスバリデーションによって誤った指摘を除外します
- **合意形成**：意見の相違は構造化されたディベートによって解決されます
- **信頼度の向上**：両エージェントが合意した問題は信頼度の高い修正対象になります

## 4フェーズ・ループ

```
┌─────────────────────────────────────────────────────────────┐
│  フェーズ1：独立レビュー                                      │
│    スロット A がレビュー → <backend>_review.md                 │
│    スロット B がレビュー → <backend>_review.md                 │
│    両エージェントにはファイルパスの一覧のみが渡され（2回目の  │
│    イテレーション以降は前回からの git diff も付与）、必要な    │
│    ファイルは自分のツールで読みに行きます。ファイルの中身を    │
│    まるごと prompt に埋め込むことはもうありません              │
│    （並列実行）                                                │
├─────────────────────────────────────────────────────────────┤
│  フェーズ2：クロスレビュー                                    │
│    スロット A がスロット B の指摘をレビュー                    │
│    スロット B がスロット A の指摘をレビュー                    │
│    （並列実行）                                                │
├─────────────────────────────────────────────────────────────┤
│  フェーズ3：メタレビュー                                      │
│    スロット A がスロット B の批評に応答                        │
│    スロット B がスロット A の批評に応答                        │
│    各エージェントには、自分のフェーズ1レビュー、相手の         │
│    フェーズ1レビュー、自分がフェーズ2で行った相手への          │
│    クロスレビュー、そして自分が受け取ったフィードバックが      │
│    毎回すべて渡されるため、指摘が合意形成の途中で              │
│    こっそり消えることがありません                              │
│    （並列実行）                                                │
├─────────────────────────────────────────────────────────────┤
│  フェーズ4：統合                                               │
│    --fixer で選択した Agent が全記録を確認します。review-only  │
│    は未解決指摘を読み取り専用で報告し、apply-fixes は既定で    │
│    IN_SCOPE のみ修正。PRE_EXISTING は opt-in が必要です。       │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
              apply-fixes はフェーズ1に戻って検証可能。
              review-only は統合完了後に終了
```

## クイックスタート

```bash
# ワークスペースにクローンまたはコピー
cd adversarial-review

# 対象プロジェクトに対して実行（標準入力がTTYの場合、フェーズ4の
# 修正実装をどちらのエージェントに任せるか対話的に尋ねられます）
./adversarial_review.sh claude codex ../my-project

# オプション付き
./adversarial_review.sh -m 5 -v claude codex ../my-project
./adversarial_review.sh -f codex claude codex ../my-project
./adversarial_review.sh -f claude claude codex ../my-project
./adversarial_review.sh --base main claude codex ../my-project
./adversarial_review.sh --include-pre-existing claude codex ../my-project

# ドライラン（実際にAPIを呼ばずに、何が実行されるかを確認）
./adversarial_review.sh --dry-run --base main --slot-a claude --slot-b codex --target-dir ../my-project
```

## 必要要件

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）または `apt install jq`（Linux）
- **coreutils**（macOSのみ、timeoutコマンド用）：`brew install coreutils`

## 使い方

```bash
./adversarial_review.sh [オプション] <slot_a> <slot_b> <対象ディレクトリ>

オプション：
    -h, --help              ヘルプを表示
    -m, --max-iters N       最大イテレーション数（デフォルト：3）
    -p, --prompt FILE       今回のフェーズ1レビュー基準を追加
    -v, --verbose           詳細出力
    -t, --timeout MIN       エージェント呼び出しごとのタイムアウト（分、デフォルト：10）
    -f, --fixer AGENT       フェーズ4の修正実装担当：claude | codex
                            （省略時、TTYであれば対話的に尋ねる。
                            非対話環境では codex がデフォルト）
    --slot-a AGENT          レビュースロット A のバックエンド：claude | codex
    --slot-b AGENT          レビュースロット B のバックエンド：claude | codex
    --target-dir PATH       レビュー対象のプロジェクトディレクトリ
    -b, --base REF          この Git ref との差分ファイルのみレビュー
                            （未コミット・未追跡のソースも含む）
    --include-pre-existing  フェーズ4で PRE_EXISTING も修正
                            （デフォルトは報告のみで変更しない）
    --review-only           フェーズ4を読み取り専用 Backend 経路で実行し、
                            未解決の指摘だけを報告して Target を変更しない
                            （--apply-fixes と排他）
    --apply-fixes           今回の実行でフェーズ4に既存の書き込み
                            権限の挙動を維持する意図を宣言
                            （--review-only と排他）
    --result-file PATH      終了時にバージョン付き JSON 結果をアトミック出力
    --status                必須の対象ディレクトリに対応する状態を表示
    --reset                 必須の対象ディレクトリに対応する全状態をリセット
    --reset-circuit         必須の対象ディレクトリのサーキットブレーカーをリセット
    --circuit-status        必須の対象ディレクトリのサーキットブレーカー状態を表示
    --dry-run               Agent 呼び出し・レビュー結論なしでプレビュー。
                            --review-only の代わりにはならない
```

自動化からの呼び出しでは、安定した[プロセス終了ステータス契約](exit-statuses.ja.md)
を参照してください。clean、findings 残存、未完了レビュー、不正な呼び出し、
Backend 失敗、書き込み境界違反を区別します。

自動化で構造化された詳細も必要な場合は `--result-file PATH` を追加します。
このオプションの解析後は、以降のすべての終了経路でスキーマバージョン付きの
JSON オブジェクトを出力先へアトミックに置き換え、ターミナル出力は変えません。
フィールド、データソース、Target 変更一覧、dry-run の意味は
[機械可読結果契約](result-file.ja.md)を参照してください。

3つの必須入力は、それぞれ位置形式または長形式オプションで指定でき、自由に
混在できます。両スロットに同じバックエンドを指定しても実行は継続しますが、
レビュー多様性低下の警告が表示されます。従来の単一位置引数形式は拒否され、
対象パスがスロット A として誤解釈されることはありません。

`--base` は任意指定で、自動推測は行いません。指定するとフェーズ1は、
その ref に対して差分のあるレビュー対象ソースだけに限定されます。
コミット済み・ステージ済み・未ステージ・未追跡の変更を含み、既存の
拡張子許可リストと生成物／ベンダーディレクトリの除外規則も適用されます。
ref が無効、対象が Git ワークツリーではない、または解決後の範囲が空の
場合は、エージェントを呼び出す前に失敗します。`--base` を省略した場合、
従来のディレクトリ全体スキャンは変わりません。API 使用量を消費する前に
`--dry-run` と組み合わせ、モード・ファイル数・一覧を確認できます。

各指摘には `IN_SCOPE` または `PRE_EXISTING` が付きます。`--base` 指定時は
変更ファイル境界を分類の基準とし、未指定時は対象行の `git blame`/`git log`
で履歴を確認します。apply-fixes モードでは、フェーズ4は通常 `IN_SCOPE` のみを
修正し、既存問題は別セクションに列挙します。両カテゴリを意図的に修正する
場合だけ `--include-pre-existing` を使用してください。dry-run は組み立てられる
フェーズ4ポリシーを表示し、`--status <slot_a> <slot_b> <対象ディレクトリ>` はスコープ別の
修正／報告件数を表示します。

`--review-only` と `--apply-fixes` を使うと、今回の実行でフェーズ4に
書き込み権限を与えず読み取り専用で統合するか、書き込み権限を与えて修正を
適用するかを明示できます。両者は互いに排他的で、両方指定すると依存関係
チェックやエージェント呼び出しの前にエラーになります。review-only でも
4フェーズすべてを実行し、フェーズ4はフェーズ1〜3と同じ読み取り専用 Backend
契約を使用します。未解決の `IN_SCOPE` と `PRE_EXISTING` の指摘を分けて報告し、
修正済みとは表現しません。両方省略した場合は、現在の暗黙的な apply-fixes の
挙動を維持して移行警告を表示します。新しい自動化・Skill・Plugin はいずれかを
明示的に指定してください。この互換デフォルトは将来削除される可能性があります。

| モード | Agent 実行 | フェーズ4の Target 権限 | 用途 |
| --- | --- | --- | --- |
| `--review-only` | あり、4フェーズすべて | 読み取り専用 | 実レビューと未解決 finding レポートを生成。 |
| `--apply-fixes` | あり | 書き込み可能 | 許可された修正を適用し、残項目を報告。 |
| `--dry-run`（どちらのモードとも併用可） | なし | Agent 権限なし | スコープとポリシーのプレビューのみ。レビュー結論を生成せず、`--review-only` の代わりにはならない。 |

安定したプロセス終了ステータスは次のとおりです。

| ステータス | 分類 |
| ---: | --- |
| `0` | Clean review |
| `10` | Review-only 完了、findings あり |
| `11` | Apply-fixes 完了、findings あり |
| `12` | Incomplete review |
| `64` | Invalid invocation |
| `70` | Agent/Backend failure |
| `77` | Write-boundary violation |

正確な意味は[終了ステータス契約](exit-statuses.ja.md)を参照してください。機械利用者
向けの[結果ファイル契約](result-file.ja.md)には、全フィールド、JSON 例、外側の
LLM/Skill による判断例があります。

状態はターゲットディレクトリごとに分離されています（下記「状態ディレクトリ」参照）。特定のプロジェクトの履歴を確認・リセットしたい場合は、必須のスロット構成と、レビュー時に指定したのと同じ `<対象ディレクトリ>` を `--status`/`--reset` などに渡してください。

## プロジェクト構成

```
adversarial-review/
├── adversarial_review.sh    # メインスクリプト
├── lib/
│   ├── date_utils.sh        # クロスプラットフォーム日付ユーティリティ
│   ├── circuit_breaker.sh   # 無限ループを防止
│   └── response_analyzer.sh # エージェントの出力を解析
├── prompts/
│   ├── initial_review.md    # フェーズ1：独立レビュー prompt
│   ├── cross_review.md      # フェーズ2：クロスレビュー prompt
│   ├── meta_review.md       # フェーズ3：メタレビュー prompt
│   └── synthesis.md         # フェーズ4：統合 prompt
└── state/                   # ターゲットディレクトリごとの状態（.gitignore済み）
    └── <プロジェクトslug>-<hash>/
        ├── artifacts/        # 各イテレーションのエージェント出力
        ├── logs/             # 実行ログ
        ├── tracking.json     # 状態管理ファイル
        └── .circuit_breaker.json
```

## 状態ディレクトリ

実行対象にした各ターゲットディレクトリは、`state/` 以下に専用の状態フォルダを持ちます。フォルダ名はディレクトリ名とフルパスの短いハッシュを組み合わせたもの（同名だが場所が異なるディレクトリ同士が衝突しないように）です。これにより：

- プロジェクトAをレビューした後にプロジェクトBをレビューしても、`tracking.json` の履歴・成果物・サーキットブレーカーのカウンターが混ざりません。
- プロジェクトAで「OPEN」になったサーキットブレーカー（や実行し忘れた `--dry-run` の残骸）が、別プロジェクトBの実行をブロックしたり汚染したりしません。
- `--status`/`--reset`/`--circuit-status`/`--reset-circuit` はいずれも2つのスロット構成と対象ディレクトリを必須入力として受け取り、そのプロジェクトの状態に絞り込みます。

## サーキットブレーカー

以下を検知することで無限ループを防止します：

- **進捗なし**：3イテレーション連続で修正が行われない
- **合意形成の停滞**：5イテレーション以上、両エージェントが合意できない
- **同じ問題の繰り返し**：3イテレーション以上、同じ修正不能な問題が検出され続ける

```bash
# 特定プロジェクトのサーキットブレーカーの状態を確認
./adversarial_review.sh --circuit-status claude codex ../my-project

# 詰まった場合はリセット
./adversarial_review.sh --reset-circuit claude codex ../my-project
```

## カスタマイズ

### カスタムレビュー Prompt

```bash
# 今回の実行にレビュー基準を追加
./adversarial_review.sh -p my_review_prompt.md claude codex ../project
```

このファイルは引数検証時に一度だけ読み込まれ、区切り付きの基準セクションとして
組み込みのフェーズ1 Prompt に追加されます。Agent ID Header、作業ディレクトリの
コンテキスト、レビュー範囲、Finding Scope 規則、必須 Status Block を置き換えず、
`prompts/` 配下のファイルも変更しません。パスが存在しない、読み取れない、または
通常ファイルでない場合は、どちらのエージェントも起動する前に失敗します。実行ごとの
基準は互いに分離されます。

フェーズ1〜3は各 Backend の呼び出し境界で読み取り専用を強制します。Claude は
読み取り／検索ツールと限定的に許可された `git log`、`git blame` のみを非対話拒否
モードで使用し、Codex は読み取り専用 Sandbox を使用します。`--apply-fixes`
（または暗黙のデフォルト）では、フェーズ4で選択された Fixer だけが書き込み権限を
得ます。`--review-only` ではフェーズ4も読み取り専用境界を維持し、統合の前後で
Target の内容と mtime の指紋を検査します。

### 環境変数

```bash
MAX_ITERATIONS=5      # 最大イテレーション数を上書き
TIMEOUT_MINUTES=15    # エージェント呼び出しごとのタイムアウト
VERBOSE=1             # 詳細出力を有効化
DRY_RUN=1             # 実行内容のみ表示
FIXER=codex           # フェーズ4の修正実装担当：claude | codex
```

## 仕組み

### エージェントのステータスブロック

各エージェントは、スクリプトが解析するための構造化ステータスブロックを出力の末尾に含めます：

```
---REVIEW_STATUS---
ISSUES_FOUND: 3
CRITICAL_COUNT: 1
HIGH_COUNT: 1
MEDIUM_COUNT: 1
LOW_COUNT: 0
ISSUE_SCOPES: CLAUDE-1=IN_SCOPE, CLAUDE-2=PRE_EXISTING, CLAUDE-3=IN_SCOPE
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: Found critical type mixing bug
---END_REVIEW_STATUS---
```

### 終了条件

以下のいずれかでループが終了します：
1. **フェーズ1で両エージェントが NO_ISSUES を報告**
   （apply-fixes のみ。review-only は統合まで継続）
2. **統合フェーズが EXIT_SIGNAL: true で完了**
3. **最大イテレーション数に到達**
4. **サーキットブレーカーが作動**（停滞を検知）

### 成果物（Artifacts）

各イテレーションで以下が生成されます：
- `iter{N}_1_<backend>_review.md` - スロット A の初期レビュー
- `iter{N}_1_<backend>_review.md` - スロット B の初期レビュー
- `iter{N}_2_<backend>_on_<other_backend>.md` - クロスレビュー
- `iter{N}_3_<backend>_meta.md` - メタレビュー
- `iter{N}_4_synthesis.md` - 最終的な統合結果と修正内容

`<backend>` は常に実際の `claude` または `codex` で、スロット名にはなりません。
異種構成では従来のパスを維持します。同一バックエンド構成では、衝突防止のため
変更のないファイル名を `artifacts/slot-a/` と `artifacts/slot-b/` に分けて格納します。

各エージェント返信には `*.invocation.json` が対応し、フェーズ、Backend、有効な
`execution_mode`、ネイティブ権限／Sandbox モード、許可ツール、実際の書き込み
許可の有無を記録します。`execution_mode` と `write_authorized` を組み合わせると、
フェーズ4に書き込み権限が与えられた、または与えられなかった根拠を確認できます。レビュー
呼び出しでは構造化された `*.raw.log` イベント（Claude の `stream-json`、Codex の
`--json`）も保持し、拒否または契約外の書き込み要求を監査できます。Target の変更を検出すると
`iter{N}_phase_*_write_violation.json` に指紋を記録して停止しますが、ユーザーの
ファイルはロールバックしません。

上記の Codex 生成ファイルにはそれぞれ対応する `iter{N}_*_*.raw.log` も出力され
ます。`codex exec` の標準出力は最終回答だけでなく、推論サマリーや shell/ツール
呼び出し、ファイルダンプを含む完全な実行トランスクリプトです。そのため `.md`
ファイルは `codex exec -o`（`--output-last-message`）で最終回答のみを抽出した
ものにし、後続フェーズへ渡す際に肥大化しないようにしています。完全な記録は
デバッグ用に `.raw.log` に残ります。

## リポジトリ単位の Skill

実装後または commit/PR 前の敵対的レビュー用として
`.agents/skills/adversarial-review` を同梱しています。`$adversarial-review` を明示的に
呼び出すか、その目的を明確に述べると暗黙に検出されます。通常のコード説明、軽量な
単独 reviewer のレビュー、一般的なデバッグ、PR 公開だけの要求は対象外です。信頼済み
Target Repo で Adapter は現在の workspace を特定します。
明示 baseline を優先し、worktree の変更だけなら `HEAD`、feature branch に commit が
ある場合（未コミット変更との混在を含む）は既知のローカル default branch
（`init.defaultBranch`、次に `main`／`master`）を使います。
異種の `claude`／`codex` reviewer slots を選択し、既定は `review-only` です。明確な
review-and-fix 要求だけが `apply-fixes` を選択し、Fixer の明示指定も必須です。detached
HEAD、shallow history、local default branch を特定できない場合、または欠落・古い可能性がある remote baseline しかない場合は
Agent 呼び出し前に停止します。追跡済み feature branch では、local default と対応する
remote-tracking default ref が一致する必要があります。一致時は fetch 未実行を明示して
続行でき、欠落または不一致なら明示 baseline、あるいは fetch／branch 調整の個別許可を
求めます。Adapter 自身は fetch を自動実行しません。

Adapter は最初に `PATH`、次に Skill を含むリポジトリのルートから
`adversarial_review.sh` を解決します。Skill を単独でインストールする場合は、
`ADVERSARIAL_REVIEW_BIN` を設定するか `--cli <path>` を明示します。

実際の Agent 呼び出し前に、Adapter は Target Repo、baseline、reviewer slots、モードを
表示します。まず CLI の必須 slot オプション、選択 backend の実行ファイルと認証、
`jq`、CLI と構文互換の `timeout` サポートを確認します。不足時は依存関係の
インストール、認証情報の
変更、レビュー呼び出しを行わず停止します。既定は異種 `claude`／`codex` です。明示的な
`claude`／`claude` または `codex`／`codex` は許可しますが、レビュー多様性の低い
same-model redundancy として説明します。その後、同じ値で dry-run を実行します。
文書化された dry-run 出力に有効で空ではなく、妥当な大きさの Review Scope がある場合だけ
実レビューを開始します。空、解析不能、または 500 ファイル超の scope は安全に停止します。
各 preview path は選択した baseline の Git delta に含まれる必要があるため、上限未満でも
意図しないリポジトリ全体 scope は拒否されます。
result schema version 1 のみを受け付け、必須フィールド、フィールド間の整合性、
プロセス／結果終了ステータスを検証し、ターミナル prose や tracking 状態へフォールバックしません。
モード、scope/base、reviewer/Fixer 割り当て、終了理由、反復回数、Finding Scope 別件数、
変更ファイル、検証結果、State/Synthesis/Artifacts パスを表示し、clean、findings、最大反復、
circuit open、不正な呼び出し、Agent/backend 失敗、書き込みポリシー違反をそれぞれ実行可能な
説明として区別します。apply-fixes 後は機械結果の適用済みファイルと Target Repo Git diff の全パスを
別々に示し、未解決 findings と区別します。リポジトリ文書に安全な検証コマンドがある場合、
呼び出し側が最上位かつ関連するものを明示的に渡します。実行ファイルと反復可能な引数を構造化
argv として渡し、Adapter は shell で再解析せず直接実行します。ない場合は未提供と報告し、
各対応ツールの引数形状は固定かつ有界で、runner、shell、設定、収集対象ファイルを選べる
追加引数は Agent 呼び出し前に拒否します。
依存関係をインストールしません。レビュー許可は commit、push、PR 作成、fetch、reset、clean、依存関係の
インストール、pre-existing findings の変更には拡張されません。

`tests/test_skill_scenarios.sh` は fixture Target Repo と fake CLI を使い、モデル呼び出しや
サブスクリプションなしで clean、findings remaining、許可済み／曖昧な修正意図、変更ファイルの
開示、検証コマンドの有無、禁止された権限拡張、reviewer 選択、前提条件エラー、
baseline 選択、曖昧な Git 状態、異常な Review Scope、デフォルト CLI 検出を
決定的に検証します。
さらに、モデル非依存の routing-policy oracle で代表的な暗黙の実装後レビュー prompt と、コード説明、軽量レビュー、デバッグ、
PR 公開の near-miss を固定します。主 Skill は簡潔に保ち、baseline の例、結果解釈、一般的な
preflight／互換性対処は必要時だけ workflow reference から読み込みます。Skill は CLI Adapter
であり、4 フェーズ、tracking 配置、機械結果契約を複製しません。

## 研究背景

このアプローチは以下の研究に基づいています：

- [D3: Debate, Deliberate, Decide](https://arxiv.org/abs/2410.04663) - 敵対的マルチエージェント評価フレームワーク
- [ChatEval](https://github.com/thunlp/ChatEval) - LLM評価のためのマルチエージェント・ディベート
- [AI Debate Research](https://arxiv.org/html/2410.04663v1) - ディベートを行うLLMがより正確な結果を生むことを示す研究

研究から得られた主な知見：
- マルチエージェント・ディベートは幻覚と誤検知を減らす
- 3〜7体のエージェントが精度とコストのバランスとして最適
- 敵対的検証は合意の質を向上させる

## コストに関する考慮事項

各イテレーションで6回のAPI呼び出し（3組の並列呼び出し）が発生します：
- フェーズ1：2回（スロット A + スロット B）
- フェーズ2：2回（スロット A + スロット B）
- フェーズ3：2回（スロット A + スロット B）
- フェーズ4：1回（`--fixer` で選択したエージェント）

最大3イテレーションの場合、最悪ケースで1回のレビューあたり約21回のAPI呼び出しになります。

個々の呼び出しを軽く保つための工夫が2つあります：

- **フェーズ1ではファイルの中身をまるごと prompt に埋め込まなくなりました。** エージェントに渡されるのはファイルパスの一覧（2回目のイテレーション以降は前回からの `git diff` も付与）だけで、実際に必要なファイルは自分のツールで読みに行きます。コードベース全体を prompt に貼り付けることはありません。
- **`--fixer` を使うことで、最も重い工程（フェーズ4。フェーズ1〜3の全ディベート履歴を再度渡す必要がある）を、余裕のあるエージェントの割り当てに回すことができます。** 非対話実行時のデフォルトは Codex になっており、この負荷がデフォルトで Claude 側の使用量だけを圧迫することはありません。

## コントリビューション

これは実験的なプロトタイプです。改善のアイデアとして：
- 他のモデル（Gemini、ローカルLLMなど）のサポート追加
- 過去の精度に基づく重み付け投票の実装
- コスト追跡と予算管理の追加
- 成果物を閲覧するためのWeb UIの構築

## ライセンス

MIT

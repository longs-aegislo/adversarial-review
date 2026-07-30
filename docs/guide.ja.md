[English](guide.md) | [中文](guide.zh.md) | **日本語**

# Adversarial Review 詳細ガイド

[README に戻る](../README.ja.md) · [Fork 変更履歴](fork-notes.ja.md)

Claude と GPT Codex による敵対的ディベートループを用いたマルチエージェント・コードレビューツールです。

[asimov-ralph](https://github.com/frankbria/ralph-claude-code) のパターンと [AI Debate](https://arxiv.org/abs/2410.04663) に関する研究をベースにしています。

## このフォークについて

このフォークのアップストリームとの差分は、
[Fork 変更履歴](fork-notes.ja.md)で個別に管理しています。

## コンセプト

2つのAIエージェント（Claude と GPT Codex）がそれぞれ独立してコードをレビューし、その後複数ラウンドのディベートを通じてお互いの指摘を批評し合います。この敵対的なプロセスには次のような利点があります：

- **より多くの問題を発見**：異なるモデルは異なる問題を見つけます
- **誤検知の排除**：クロスバリデーションによって誤った指摘を除外します
- **合意形成**：意見の相違は構造化されたディベートによって解決されます
- **信頼度の向上**：両エージェントが合意した問題は信頼度の高い修正対象になります

## 4フェーズ・ループ

```
┌─────────────────────────────────────────────────────────────┐
│  フェーズ1：独立レビュー                                      │
│    Claude がコードをレビュー → claude_review.md               │
│    Codex がコードをレビュー  → codex_review.md                │
│    両エージェントにはファイルパスの一覧のみが渡され（2回目の  │
│    イテレーション以降は前回からの git diff も付与）、必要な    │
│    ファイルは自分のツールで読みに行きます。ファイルの中身を    │
│    まるごと prompt に埋め込むことはもうありません              │
│    （並列実行）                                                │
├─────────────────────────────────────────────────────────────┤
│  フェーズ2：クロスレビュー                                    │
│    Claude が Codex の指摘をレビュー → claude_on_codex.md       │
│    Codex が Claude の指摘をレビュー → codex_on_claude.md       │
│    （並列実行）                                                │
├─────────────────────────────────────────────────────────────┤
│  フェーズ3：メタレビュー                                      │
│    Claude が Codex の批評に応答 → claude_meta.md               │
│    Codex が Claude の批評に応答 → codex_meta.md                │
│    各エージェントには、自分のフェーズ1レビュー、相手の         │
│    フェーズ1レビュー、自分がフェーズ2で行った相手への          │
│    クロスレビュー、そして自分が受け取ったフィードバックが      │
│    毎回すべて渡されるため、指摘が合意形成の途中で              │
│    こっそり消えることがありません                              │
│    （並列実行）                                                │
├─────────────────────────────────────────────────────────────┤
│  フェーズ4：統合と実装                                        │
│    Claude または Codex（--fixer で選択）がすべてのディベート   │
│    記録を確認し、デフォルトでは IN_SCOPE のみを修正します。    │
│    PRE_EXISTING は --include-pre-existing 指定時のみ修正します │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
              フェーズ1に戻って修正を検証し、
              両エージェントが NO_ISSUES を報告するまで繰り返す
```

## クイックスタート

```bash
# ワークスペースにクローンまたはコピー
cd adversarial-review

# 対象プロジェクトに対して実行（標準入力がTTYの場合、フェーズ4の
# 修正実装をどちらのエージェントに任せるか対話的に尋ねられます）
./adversarial_review.sh ../my-project

# オプション付き
./adversarial_review.sh -m 5 -v ../my-project        # 5イテレーション、詳細出力
./adversarial_review.sh -f codex ../my-project        # Codex が修正を実装
./adversarial_review.sh -f claude ../my-project       # Claude が修正を実装
./adversarial_review.sh --base main ../my-project     # ブランチ差分のみレビュー
./adversarial_review.sh --include-pre-existing ../my-project  # 既存問題も修正

# ドライラン（実際にAPIを呼ばずに、何が実行されるかを確認）
./adversarial_review.sh --dry-run --base main ../my-project
```

## 必要要件

- **claude CLI**：`npm install -g @anthropic-ai/claude-code`
- **codex CLI**：`npm install -g @openai/codex`
- **jq**：`brew install jq`（macOS）または `apt install jq`（Linux）
- **coreutils**（macOSのみ、timeoutコマンド用）：`brew install coreutils`

## 使い方

```bash
./adversarial_review.sh [オプション] <対象ディレクトリ>

オプション：
    -h, --help              ヘルプを表示
    -m, --max-iters N       最大イテレーション数（デフォルト：3）
    -p, --prompt FILE       今回のフェーズ1レビュー基準を追加
    -v, --verbose           詳細出力
    -t, --timeout MIN       エージェント呼び出しごとのタイムアウト（分、デフォルト：10）
    -f, --fixer AGENT       フェーズ4の修正実装担当：claude | codex
                            （省略時、TTYであれば対話的に尋ねる。
                            非対話環境では codex がデフォルト）
    -b, --base REF          この Git ref との差分ファイルのみレビュー
                            （未コミット・未追跡のソースも含む）
    --include-pre-existing  フェーズ4で PRE_EXISTING も修正
                            （デフォルトは報告のみで変更しない）
    --status [DIR]          現在の状態を表示（DIR指定時はそのプロジェクトのみ）
    --reset [DIR]           すべての状態をリセット（DIR指定時はそのプロジェクトのみ）
    --reset-circuit [DIR]   サーキットブレーカーのみリセット（DIR指定時はそのプロジェクトのみ）
    --circuit-status [DIR]  サーキットブレーカーの状態を表示（DIR指定時はそのプロジェクトのみ）
    --dry-run               実行せずに何が行われるかを表示
```

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
で履歴を確認します。フェーズ4は通常 `IN_SCOPE` のみを修正し、既存問題は
別セクションに列挙します。両カテゴリを意図的に修正する場合だけ
`--include-pre-existing` を使用してください。dry-run は組み立てられる
フェーズ4ポリシーを表示し、`--status <対象ディレクトリ>` はスコープ別の
修正／報告件数を表示します。

状態はターゲットディレクトリごとに分離されています（下記「状態ディレクトリ」参照）。特定のプロジェクトの履歴を確認・リセットしたい場合は、レビュー時に指定したのと同じ `<対象ディレクトリ>` を `--status`/`--reset` などに渡してください。省略した場合は後方互換のために残された共有／グローバルな領域にフォールバックします。

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
- `--status`/`--reset`/`--circuit-status`/`--reset-circuit` はいずれも対象ディレクトリを任意の引数として受け取り、そのプロジェクトの状態に絞り込めます。

## サーキットブレーカー

以下を検知することで無限ループを防止します：

- **進捗なし**：3イテレーション連続で修正が行われない
- **合意形成の停滞**：5イテレーション以上、両エージェントが合意できない
- **同じ問題の繰り返し**：3イテレーション以上、同じ修正不能な問題が検出され続ける

```bash
# 特定プロジェクトのサーキットブレーカーの状態を確認
./adversarial_review.sh --circuit-status ../my-project

# 詰まった場合はリセット
./adversarial_review.sh --reset-circuit ../my-project
```

## カスタマイズ

### カスタムレビュー Prompt

```bash
# 今回の実行にレビュー基準を追加
./adversarial_review.sh -p my_review_prompt.md ../project
```

このファイルは引数検証時に一度だけ読み込まれ、区切り付きの基準セクションとして
組み込みのフェーズ1 Prompt に追加されます。Agent ID Header、作業ディレクトリの
コンテキスト、レビュー範囲、Finding Scope 規則、必須 Status Block を置き換えず、
`prompts/` 配下のファイルも変更しません。パスが存在しない、読み取れない、または
通常ファイルでない場合は、どちらのエージェントも起動する前に失敗します。実行ごとの
基準は互いに分離されます。

フェーズ1〜3は各 Backend の呼び出し境界で読み取り専用を強制します。Claude は
読み取り／検索ツールと限定的に許可された `git log`、`git blame` のみを非対話拒否
モードで使用し、Codex は読み取り専用 Sandbox を使用します。書き込み権限を得るのは、
フェーズ4で選択された Fixer だけです。

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
2. **統合フェーズが EXIT_SIGNAL: true で完了**
3. **最大イテレーション数に到達**
4. **サーキットブレーカーが作動**（停滞を検知）

### 成果物（Artifacts）

各イテレーションで以下が生成されます：
- `iter{N}_1_claude_review.md` - Claude の初期レビュー
- `iter{N}_1_codex_review.md` - Codex の初期レビュー
- `iter{N}_2_claude_on_codex.md` - Claude のクロスレビュー
- `iter{N}_2_codex_on_claude.md` - Codex のクロスレビュー
- `iter{N}_3_claude_meta.md` - Claude のメタレビュー
- `iter{N}_3_codex_meta.md` - Codex のメタレビュー
- `iter{N}_4_synthesis.md` - 最終的な統合結果と修正内容

上記の Codex 生成ファイルにはそれぞれ対応する `iter{N}_*_*.raw.log` も出力され
ます。`codex exec` の標準出力は最終回答だけでなく、推論サマリーや shell/ツール
呼び出し、ファイルダンプを含む完全な実行トランスクリプトです。そのため `.md`
ファイルは `codex exec -o`（`--output-last-message`）で最終回答のみを抽出した
ものにし、後続フェーズへ渡す際に肥大化しないようにしています。完全な記録は
デバッグ用に `.raw.log` に残ります。

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
- フェーズ1：2回（Claude + Codex）
- フェーズ2：2回（Claude + Codex）
- フェーズ3：2回（Claude + Codex）
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

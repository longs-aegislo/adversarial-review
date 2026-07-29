[English](README.md) | [中文](README.zh.md) | **日本語**

# Adversarial Review（敵対的コードレビュー）

Claude と GPT Codex による敵対的ディベートループを用いたマルチエージェント・コードレビューツールです。

[asimov-ralph](https://github.com/frankbria/ralph-claude-code) のパターンと [AI Debate](https://arxiv.org/abs/2410.04663) に関する研究をベースにしています。

## このフォークについて

本リポジトリは [alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review)（`upstream` remote として保持）からのフォークです。フォーク後、実際のLaravelプロジェクトに対してこのツールを動かし、見つかったバグを多数修正しており、アップストリームとの主な差分は以下の通りです：

- **`codex` の呼び出し方法を修正**：従来の `run_codex()` は現在の `codex` CLI とは一致しない古いCLI構文（`-q --full-auto --prompt`）を使用していました。現在は `codex exec -s <sandbox_mode> --skip-git-repo-check` を使い、prompt は位置引数ではなく標準入力（stdin）経由のパイプで渡すようにしました（従来の方式では、prompt が大きいと `ARG_MAX` / `timeout: Argument list too long` エラーが発生していました）。
- **JS/Python以外のスタックに対するソース収集ロジックを修正**：従来の `collect_source_code`/`collect_file_list` は `vendor/`、`public/`、`storage/`、`bootstrap/cache/`、`dist/`、`build/` を除外しておらず、PHP/Bladeのサポートもありませんでした。そのためLaravelプロジェクトでは、プロジェクト自体のソースコードではなく、サードパーティの圧縮済みJS依存関係がprompt に詰め込まれ、Claude のコンテキスト上限も超過していました。
- **フェーズ3で相手の指摘が失われる問題を修正**：従来のメタレビュー prompt は、相手エージェントから返されたフィードバックのみを再提供しており、相手のフェーズ1における元の指摘や、自分がフェーズ2で行ったそれらへのクロスレビューは再提供していませんでした。各フェーズは以前のフェーズの記憶を持たない、独立したステートレスなCLI呼び出しであるため、これによりどちらか一方のエージェントの指摘がすべて最終的な合意からこっそり抜け落ちていました。現在の `run_phase_3()` は両エージェントに対して完全なコンテキストを再構築します。
- **`parse_status_block` の「最後のブロック」抽出ロジックを修正**：従来の実装は、テキスト中に出現するすべての `---STATUS---...---END_STATUS---` マーカーの組（prompt テンプレート自体に組み込まれたEXAMPLEブロックも含む）を連結してしまい、壊れた／重複したJSONを生成していました。現在はawkベースのスキャナーに変更し、最後の本物のブロックのみを保持するようにしています。
- **`-f/--fixer` を追加**：フェーズ4の修正実装をClaudeとCodexのどちらに任せるか選べるようになりました（TTYでは対話的に尋ねられ、フラグや環境変数でも指定可能）。これにより、最もコストのかかる工程を余裕のあるエージェントに回せます。
- **フェーズ1を刷新し、ファイルの中身をまるごと埋め込むのをやめました**：エージェントには、コードベース全体をprompt に貼り付ける代わりに、ファイルパスの一覧（2回目のイテレーション以降は `HEAD` に対する `git diff` も付与）が渡され、必要なファイルは自分で読みに行くようになりました。詳細は下記の「コストに関する考慮事項」を参照してください。
- **ターミナル出力に各フェーズの指摘内容の要約を追加**：各フェーズで、問題の件数だけでなく、エージェントが出した一行要約も表示されるようになりました。

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
│    記録を確認し、どの指摘が有効かを判断した上で、              │
│    高/中信頼度の問題に対して修正を実装します                    │
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

# ドライラン（実際にAPIを呼ばずに、何が実行されるかを確認）
./adversarial_review.sh --dry-run ../my-project
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
    -p, --prompt FILE       カスタム初期レビュー prompt
    -v, --verbose           詳細出力
    -t, --timeout MIN       エージェント呼び出しごとのタイムアウト（分、デフォルト：10）
    -f, --fixer AGENT       フェーズ4の修正実装担当：claude | codex
                            （省略時、TTYであれば対話的に尋ねる。
                            非対話環境では codex がデフォルト）
    --status                現在の状態を表示
    --reset                 すべての状態をリセット
    --reset-circuit         サーキットブレーカーのみリセット
    --circuit-status        サーキットブレーカーの状態を表示
    --dry-run               実行せずに何が行われるかを表示
```

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
├── artifacts/               # 各イテレーションのエージェント出力
├── logs/                    # 実行ログ
└── tracking.json            # 状態管理ファイル
```

## サーキットブレーカー

以下を検知することで無限ループを防止します：

- **進捗なし**：3イテレーション連続で修正が行われない
- **合意形成の停滞**：5イテレーション以上、両エージェントが合意できない
- **同じ問題の繰り返し**：3イテレーション以上、同じ修正不能な問題が検出され続ける

```bash
# サーキットブレーカーの状態を確認
./adversarial_review.sh --circuit-status

# 詰まった場合はリセット
./adversarial_review.sh --reset-circuit
```

## カスタマイズ

### カスタムレビュー Prompt

```bash
# 独自のレビュー基準を使用
./adversarial_review.sh -p my_review_prompt.md ../project
```

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

# Repository Instructions

## GitHub identity and tooling

- 本机处理 `SysAegislo/*` 仓库时，默认使用本地 `gh` CLI，不使用 GitHub App Connector。
- GitHub App Connector 绑定的是个人 GitHub 账号，不得用于 `SysAegislo/*` 的读取或写入操作。
- 对 `SysAegislo/*` 执行 GitHub 写操作前，先确认本地仓库的 `origin` 和当前 `gh` 认证身份。
- 如果 GitHub App 与 `gh` CLI 的访问结果不同，以已认证的 `gh` CLI 为准。

## GitHub comment formatting and signature

- Codex 发布或更新 GitHub 评论时，正文必须使用实际换行，不得把字面量 `\n` 当作换行发送。
- 优先使用能原样保留多行内容的方式（例如 `--body-file`）；发布后确认评论中没有意外显示字面量 `\n`。
- Codex 发布的 GitHub 评论末尾空一行并署名 `by Codex`。

## Documentation synchronization

- 功能或用户可见行为改修完成后，必须同步检查并更新 `README.md`、`README.zh.md`、`README.ja.md` 及其对应的三语详细文档，确保功能、CLI 和行为说明保持一致；即使无需修改，也要确认三语文档没有落后。

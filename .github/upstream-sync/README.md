# 跟上上游（Wei-Shaw/sub2api）

本仓库 `kkkkkkone-bot/sub2api` 是上游的镜像分支。`main` = 上游目标版本 + 一个自有提交
（`.github/upstream-sync/` 与 `.github/workflows/sync-upstream.yml`），其余内容跟随上游。

## 一次性启用（只做一次）

1. **把 workflow 放进 main**：GitHub 网页 → `Add file` → `Create new file` →
   路径填 `.github/workflows/sync-upstream.yml` → 粘贴约 30 行的内容 → *Commit directly to the main branch*。
   > 为什么不能由脚本推：`GITHUB_TOKEN` / GCM 的 OAuth token 都没有 `workflows` 权限，
   > 任何**包含 workflow 文件变更**的推送都会被 GitHub 拒绝（`refusing to allow a GitHub App to
   > create or update workflow ... without workflows permission`）。所以只有这一个文件需要手工放。
2. **Actions**：本仓库已启用（`Settings → Actions` 里上游那 4 个 workflow 是 active），无需再开。
3. **先验证再放开**：`Actions → Sync upstream → Run workflow`，勾上 `dry_run` 跑一次；
   确认输出后，取消 `dry_run` 再跑一次。

之后每 3 小时（UTC `0 */3 * * *`）自动检查；上游出新版 → 同步并推送 → Zeabur 按分支自动重建。

## 同步逻辑（`.github/upstream-sync/sync.sh`）

1. **解析目标**：`release` = 上游最新正式 Release 对应的 **VERSION 提交**；`main` = `upstream/main`。
2. **合成一个提交**：`main` 重置到目标，再把 `.github/workflows/`、`.github/upstream-sync/`
   从 `origin/main` 原样取回，`git commit`。
3. **推送**：内容与 `origin/main` 一致则跳过；否则 `git push --force-with-lease origin HEAD:main`。

> **为什么不用 rebase**：rebase 会把上游对 workflow 文件的改动带进推送，而 `GITHUB_TOKEN`
> 没有 `workflows` 权限，推送会被拒绝。第 2 步让推送里**永远不含 workflow 变更**。
> 副作用：`.github/workflows/` 会固定在首次取回时的版本，不再跟随上游（对网关运行无影响）。

> **为什么 release 模式不用裸 tag**：上游先打 tag，随后才提交 `chore: sync VERSION to X [skip ci]`；
> tag 那个提交里 `backend/cmd/server/VERSION` 还是**上一版**（实测 v0.2.13 tag 上写着 0.2.12）。
> 用 VERSION 提交才能让后台版本号显示正确、不误报"可升级"。

## 自有改动放哪

只放这两个路径：`.github/upstream-sync/`（脚本与本文档）、`.github/workflows/sync-upstream.yml`。
它们每次同步都会被原样保留；main 上其它文件会被上游内容覆盖，别直接改。

## 手动执行（Actions 不可用 / 本地排查）

```bash
bash .github/upstream-sync/sync.sh               # 跟最新正式版
MODE=main bash .github/upstream-sync/sync.sh     # 跟上上游 main
DRY_RUN=true bash .github/upstream-sync/sync.sh  # 只看不动
```

纯 git 版本（Windows 上建议加 `-c http.sslBackend=openssl` 避免 schannel 报错）：

```powershell
git fetch upstream --tags --prune; git fetch origin --prune
git checkout -B main 3f1a2ea0a                      # 目标：release 的 VERSION 提交，或 upstream/main
git checkout origin/main -- .github/workflows .github/upstream-sync
git add -A; git commit -m "chore: sync upstream"
git push --force-with-lease origin HEAD:main
```

## 部署与回滚

- Zeabur 按 `kkkkkkone-bot/sub2api` 的 `main` 分支自动重建：同步即上线（含数据库迁移）。
  上游发版说明里标注的破坏性变更要提前看（例如 v0.2.14 的安装期管理员校验只影响全新安装）。
- 回滚：
  ```powershell
  git checkout -B main v0.2.13
  git push --force-with-lease origin HEAD:main
  ```
- GitHub 会在仓库连续 60 天无活动时停掉定时 workflow，手动 Run 一次即可恢复。
- 推送方是 `GITHUB_TOKEN`，不会触发本仓库其它 Actions（避免 CI 风暴）；Zeabur 的 push webhook 照常收到。

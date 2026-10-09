#!/usr/bin/env bash
# 上游同步逻辑：由 .github/workflows/sync-upstream.yml 调用，也可本地 bash 直接运行。
#
# 策略（故意不用 rebase）：
#   1) 解析目标：release = 上游最新正式 Release 对应的 VERSION 提交；main = upstream/main
#   2) main 重置到目标，再把 .github/workflows 与 .github/upstream-sync 从 origin/main 原样取回，
#      合成"一个"新提交 —— 这样推送里永远不含 workflow 文件变更，GITHUB_TOKEN 才推得动
#      （GitHub App token 没有 workflows 权限，改 workflow 文件会被拒绝）
#   3) 内容与 origin/main 完全一致时直接跳过；否则 --force-with-lease 推送
#
# 环境变量：MODE=release|main（默认 release）、DRY_RUN=true|false、
#           UPSTREAM_REPO（默认 Wei-Shaw/sub2api）、UPSTREAM_BRANCH（默认 main）
set -euo pipefail

# 本脚本位于被自己重置的目录里：bash 是边读边执行的，文件被删掉后会读到"消失的文件"
# （Windows/MSYS 下表现为静默中断，实测过）。所以先把自己复制到临时目录再执行。
if [ "${SYNC_UPSTREAM_RELOCATED:-0}" != "1" ]; then
  _self="$(mktemp -t sync-upstream.XXXXXX.sh 2>/dev/null || printf '%s' "/tmp/sync-upstream.$$.sh")"
  cp "$0" "$_self"
  SYNC_UPSTREAM_RELOCATED=1 SYNC_UPSTREAM_SELF="$_self" exec bash "$_self" "$@"
fi
if [ -n "${SYNC_UPSTREAM_SELF:-}" ]; then
  trap 'rm -f "$SYNC_UPSTREAM_SELF"' EXIT
fi

UPSTREAM_REPO="${UPSTREAM_REPO:-Wei-Shaw/sub2api}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
MODE="${MODE:-release}"
DRY_RUN="${DRY_RUN:-false}"
VERSION_FILE="backend/cmd/server/VERSION"
# 这些路径的内容以本仓库 origin/main 为准，同步时原样保留
KEEP_PATHS=(.github/workflows .github/upstream-sync)

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git remote add upstream "https://github.com/${UPSTREAM_REPO}.git" 2>/dev/null \
  || git remote set-url upstream "https://github.com/${UPSTREAM_REPO}.git"
git fetch upstream --tags --prune
git fetch origin --prune

# ---------- 解析目标 ----------
branch="upstream/${UPSTREAM_BRANCH}"
target=""
if [ "$MODE" = "release" ]; then
  tag="$(gh release view --repo "$UPSTREAM_REPO" --json tagName -q .tagName 2>/dev/null || true)"
  if [ -z "$tag" ]; then
    tag="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
    echo "::warning::未从 gh 取到最新 release，回退到 tag ${tag}"
  fi
  if [ -n "$tag" ]; then
    ver="${tag#v}"
    release_commit=""
    # 上游先打 tag，之后才提交 "chore: sync VERSION to X [skip ci]"；
    # 用后者才能让构建出的二进制报告正确版本号。
    for c in $(git log --format=%H -n 30 "$branch" -- "$VERSION_FILE"); do
      if [ "$(git show "${c}:${VERSION_FILE}" | tr -d '[:space:]')" = "$ver" ]; then
        release_commit="$c"
        break
      fi
    done
    if [ -n "$release_commit" ] && git merge-base --is-ancestor "$release_commit" "$branch"; then
      target="$release_commit"
      echo "release ${tag} -> ${release_commit} (VERSION 提交)"
    else
      echo "::warning::未找到 ${tag} 的 VERSION 提交，回退到 tag"
      target="$tag"
    fi
  fi
fi
if [ -z "$target" ]; then
  target="$branch"
fi
echo "目标：${target} = $(git log -1 --format='%h %cs %s' "$target")"

# ---------- 组装新的 main ----------
git checkout -B main "$target" >/dev/null 2>&1
for path in "${KEEP_PATHS[@]}"; do
  # 不要写 "origin/main:${path}" 这种带冒号的判断：Git Bash(MSYS) 会把带冒号的参数
  # 当路径列表改写，判断会静默为假、整个还原被跳过（本地实测过，排查了很久）。
  if [ -z "$(git ls-tree origin/main -- "$path")" ]; then
    echo "::warning::origin/main 里没有 ${path}，跳过保留"
    continue
  fi
  git rm -r -q --ignore-unmatch "$path" 2>/dev/null || true
  git checkout origin/main -- "$path"
done
# 只补记已跟踪文件的变化；绝不能把未跟踪文件（例如尚未提交的 workflow 文件、本地杂物）带进提交
git add -u -- .github

if git diff --cached --quiet; then
  echo "已经是最新，无需同步"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "changed=false" >> "$GITHUB_OUTPUT"; fi
  exit 0
fi

if [ -n "${ver:-}" ]; then
  message="chore: sync upstream to v${ver}"
else
  message="chore: sync upstream to $(git log -1 --format='%h %s' "$target" | cut -c1-72)"
fi
git commit -q -m "$message"
echo "新提交：$(git rev-parse --short HEAD)（基于 $(git rev-parse --short "$target")）"
git --no-pager log --oneline -3

if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "changed=true" >> "$GITHUB_OUTPUT"; fi

if git diff --quiet origin/main HEAD; then
  echo "内容与 origin/main 一致，跳过推送"
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "dry_run=true，未推送"
  exit 0
fi

# 同样避开带冒号的 refspec（HEAD:main），Git Bash 下会被改写
git push --force-with-lease origin main
echo "已推送 origin/main（部署平台会自动重建）"

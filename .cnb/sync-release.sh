#!/usr/bin/env bash
#
# 手动同步发布：把源仓库（默认 discourse-app）指定版本的 Release 同步到一个目标仓库。
#
# 由 .cnb.yml 的 web_trigger 并行任务调用；也可以在本地手动执行：
#
#   RELEASE_SYNC_TAG=v0.0.2 \
#     ./.cnb/sync-release.sh https://gitee.com/xuxiaowei-io/discourse-app-release
#
#   ./.cnb/sync-release.sh https://gitee.com/xuxiaowei-io/discourse-app-release v0.0.2
#
# 参数：
#   $1  目标仓库地址；未给时读 RELEASE_SYNC_TARGET
#   $2  版本号（发布 tag）；未给时读 RELEASE_SYNC_TAG（web_trigger 的「版本号」输入会注入）
#
# 环境变量：
#   RELEASE_SYNC_TAG      版本号，必填；必须是源仓库真实存在的 Release tag
#   RELEASE_SYNC_SOURCE   源仓库，默认 https://cnb.cool/xuxiaowei.io/discourse-app
#   RELEASE_SYNC_TARGETS  选中的目标，分号分隔（cnb;gitee;gitlab;...）；未设置时默认全选
#   RELEASE_SYNC_TARGET_KEY
#                         当前 pipeline 对应的目标标识；未设置时不做选择过滤（本地执行）
#   PUBLISH_APK_VERSION   使用的 publish-apk 版本，默认 0.0.1-alpha.24
#   PUBLISH_APK_TARBALL   npm 上取不到该版本时的 GitHub tag 安装地址（默认按版本自动拼接）
#   RELEASE_SYNC_PACKAGE_NAME
#                         目标为 GitLab 时的 Generic Package 名称，默认 discourse-app
#   RELEASE_SYNC_ARGS     追加给 release-sync 的参数（如 "--dry-run --verbose"），可选
#
# 令牌（不写进本仓库，由 .cnb.yml 的 imports 从 discourse-app-envs 引入；只走环境变量）：
#   源仓库：CNB_SOURCE_TOKEN / CNB_RELEASE_TOKEN / CNB_SYNC_TOKEN，最后回退 CNB_TOKEN。
#           discourse-app 是私有仓库；本仓库是公开仓库时，内置 CNB_TOKEN 只能访问公开仓库，
#           因此实际使用时应提供 CNB_SOURCE_TOKEN。
#   目标仓库按平台读取（前一个优先）：
#     CNB     CNB_TARGET_TOKEN / CNB_TOKEN
#     Gitee   GITEE_TARGET_TOKEN / GITEE_SYNC_TOKEN
#     GitLab  GITLAB_TARGET_TOKEN / GITLAB_SYNC_TOKEN（需要 api，含 Package Registry 写权限）
#     GitHub  GITHUB_TARGET_TOKEN / GITHUB_SYNC_TOKEN
#     GitLink GITLINK_TARGET_TOKEN / GITLINK_SYNC_TOKEN
#     GitCode GITCODE_TARGET_TOKEN / GITCODE_SYNC_TOKEN
#
# 说明：
#   - 版本号必填，不提供「同步最新发布」的默认行为，避免误同步；
#   - 同步目标可多选、默认全选；未选中的目标在脚本入口直接跳过；
#   - GitLab 目标把附件上传到 Generic Package Registry，再创建指向通用包的 Release Link；
#     同名 package file 先删除后上传，软件包名默认 discourse-app、版本为发布 tag；
#   - publish-apk 固定版本安装到临时目录后执行，不污染工作区；
#   - 令牌只作为环境变量传给子进程，不出现在命令行参数与日志里。
set -euo pipefail

SOURCE_REPO="${RELEASE_SYNC_SOURCE:-https://cnb.cool/xuxiaowei.io/discourse-app}"
TARGET_REPO="${1:-${RELEASE_SYNC_TARGET:-}}"
TAG="${2:-${RELEASE_SYNC_TAG:-}}"
PUBLISH_APK_VERSION="${PUBLISH_APK_VERSION:-0.0.1-alpha.24}"
PUBLISH_APK_TARBALL="${PUBLISH_APK_TARBALL:-https://codeload.github.com/xuxiaowei-io/publish-apk/tar.gz/refs/tags/v${PUBLISH_APK_VERSION}}"

log() { printf '%s\n' "$*"; }
fail() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

[ -n "$TARGET_REPO" ] || fail "缺少目标仓库：请传入第一个参数或设置 RELEASE_SYNC_TARGET"
[ -n "$TAG" ] || fail "版本号必填：请在页面填写版本号（RELEASE_SYNC_TAG），或在本地设置 RELEASE_SYNC_TAG"
case "$TAG" in
  *[[:space:]]*) fail "版本号不能包含空白字符: $TAG" ;;
esac

# web_trigger 会注入 RELEASE_SYNC_TARGETS（分号分隔，默认全选）；未选中的目标直接跳过。
# 本地执行不设置 RELEASE_SYNC_TARGET_KEY，因此不做选择过滤。
TARGET_KEY="${RELEASE_SYNC_TARGET_KEY:-}"
if [ -n "$TARGET_KEY" ]; then
  case "$TARGET_KEY" in
    cnb|gitee|gitlab|github|gitlink|gitcode) ;;
    *) fail "未知的同步目标标识: ${TARGET_KEY}" ;;
  esac
  selected_targets="${RELEASE_SYNC_TARGETS:-cnb;gitee;gitlab;github;gitlink;gitcode}"
  selected_targets="${selected_targets//,/;}"
  case ";${selected_targets};" in
    *";${TARGET_KEY};"*) ;;
    *) log "未选择目标 ${TARGET_KEY}，跳过同步"; exit 0 ;;
  esac
fi

# 按目标仓库域名选择令牌；新增平台时在这里补一条。
case "$TARGET_REPO" in
  cnb.cool/*|https://cnb.cool/*|http://cnb.cool/*)
    platform='CNB'
    target_token="${CNB_TARGET_TOKEN:-${CNB_TOKEN:-}}"
    target_token_hint='CNB_TARGET_TOKEN 或 CNB_TOKEN'
    ;;
  gitee.com/*|https://gitee.com/*|http://gitee.com/*)
    platform='Gitee'
    target_token="${GITEE_TARGET_TOKEN:-${GITEE_SYNC_TOKEN:-}}"
    target_token_hint='GITEE_TARGET_TOKEN 或 GITEE_SYNC_TOKEN'
    ;;
  gitlab.com/*|https://gitlab.com/*|http://gitlab.com/*)
    platform='GitLab'
    target_token="${GITLAB_TARGET_TOKEN:-${GITLAB_SYNC_TOKEN:-}}"
    target_token_hint='GITLAB_TARGET_TOKEN 或 GITLAB_SYNC_TOKEN'
    ;;
  github.com/*|https://github.com/*|http://github.com/*)
    platform='GitHub'
    target_token="${GITHUB_TARGET_TOKEN:-${GITHUB_SYNC_TOKEN:-}}"
    target_token_hint='GITHUB_TARGET_TOKEN 或 GITHUB_SYNC_TOKEN'
    ;;
  gitlink.org.cn/*|https://gitlink.org.cn/*|http://gitlink.org.cn/*)
    platform='GitLink'
    target_token="${GITLINK_TARGET_TOKEN:-${GITLINK_SYNC_TOKEN:-}}"
    target_token_hint='GITLINK_TARGET_TOKEN 或 GITLINK_SYNC_TOKEN'
    ;;
  gitcode.com/*|https://gitcode.com/*|http://gitcode.com/*)
    platform='GitCode'
    target_token="${GITCODE_TARGET_TOKEN:-${GITCODE_SYNC_TOKEN:-}}"
    target_token_hint='GITCODE_TARGET_TOKEN 或 GITCODE_SYNC_TOKEN'
    ;;
  *)
    fail "无法识别目标平台: $TARGET_REPO（支持 cnb.cool / gitee.com / gitlab.com / github.com / gitlink.org.cn / gitcode.com）"
    ;;
esac

source_token="${CNB_SOURCE_TOKEN:-${CNB_RELEASE_TOKEN:-${CNB_SYNC_TOKEN:-${CNB_TOKEN:-}}}}"
[ -n "$source_token" ] || fail "缺少源仓库令牌：discourse-app 是私有仓库，请设置 CNB_SOURCE_TOKEN（需要 discourse-app 的 repo-release:r）"
if [ -z "${CNB_SOURCE_TOKEN:-}${CNB_RELEASE_TOKEN:-}${CNB_SYNC_TOKEN:-}" ]; then
  # 本仓库是公开仓库，流水线内置 CNB_TOKEN 只能访问公开仓库；源仓库是私有时会 401/403。
  printf '警告: 未设置专用源仓库令牌，回退到 CNB_TOKEN；若 discourse-app 为私有仓库，请改设 CNB_SOURCE_TOKEN\n' >&2
fi
[ -n "$target_token" ] || fail "缺少 ${platform} 目标令牌：请设置 ${target_token_hint}"

# GitLab 目标从 ec05bdfe 起必须指定 Generic Package 名称；版本使用发布 tag。
package_name=''
if [ "$platform" = 'GitLab' ]; then
  package_name="${RELEASE_SYNC_PACKAGE_NAME:-discourse-app}"
  case "$package_name" in
    *[[:space:]]*) fail "GitLab 软件包名不能包含空白字符: ${package_name}" ;;
  esac
fi

# release-sync 自己也会读通用环境变量；这里统一导出，避免把令牌放进命令行参数。
export RELEASE_SYNC_SOURCE_TOKEN="$source_token"
export RELEASE_SYNC_TARGET_TOKEN="$target_token"

install_dir="$(mktemp -d)"
trap 'rm -rf "$install_dir"' EXIT

log '== 同步发布 =='
log "源仓库: ${SOURCE_REPO}"
log "目标仓库: ${TARGET_REPO}"
log "版本号: ${TAG}"
log "目标平台: ${platform}"
log "publish-apk: ${PUBLISH_APK_VERSION}"
if [ "$platform" = 'GitLab' ]; then
  log "GitLab 软件包名: ${package_name}"
fi
log ''

# 固定版本安装，避免 npx 命中全局旧版本或 latest 尚未包含 release-sync 的情况。
# 优先走 npm；alpha.23 等版本尚未出现在 npm 上时（staged publish 待批准），
# 回退到同名 GitHub tag 的源码包，保证 GitLab Generic Package 上传能力可用。
if ! npm install \
  --prefix "$install_dir" \
  --no-save \
  --no-audit \
  --no-fund \
  --loglevel=error \
  "publish-apk@${PUBLISH_APK_VERSION}" >/dev/null 2>&1; then
  log "npm 上暂未取到 publish-apk@${PUBLISH_APK_VERSION}，改从 GitHub tag 安装"
  npm install \
    --prefix "$install_dir" \
    --no-save \
    --no-audit \
    --no-fund \
    --loglevel=error \
    "$PUBLISH_APK_TARBALL"
fi

extra_args=()
if [ -n "${RELEASE_SYNC_ARGS:-}" ]; then
  read -r -a extra_args <<< "$RELEASE_SYNC_ARGS"
fi

cmd=(
  "${install_dir}/node_modules/.bin/publish-apk" release-sync
  --source "$SOURCE_REPO"
  --target "$TARGET_REPO"
  --tag "$TAG"
)
if [ "$platform" = 'GitLab' ]; then
  cmd+=(--package-name "$package_name")
fi
if [ "${#extra_args[@]}" -gt 0 ]; then
  cmd+=("${extra_args[@]}")
fi

"${cmd[@]}"

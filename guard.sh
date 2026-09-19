#!/bin/bash
# zopguard —— ZopToken 自愈守护 v1.8（通用版）
# zopguard-version: 1.8
# 每 3 分钟由 launchd 调用：
#   · 检测 ZopToken 进程，异常时自动「退出→重开」
#   · v1.2 平台判据：进程活着但平台侧状态异常（假活/掉线）也会自动修复
#   · v1.4 API 直登：登录态掉线（登出/槽位到期）时用登录密钥直接调平台接口
#     恢复设备槽位，再重启客户端（客户端静默重连进主界面），零 GUI、零权限
#   · v1.5（2026-09-18）：① 每日修复上限 12→20；② 平台判据加固——
#     「设备不在列表」与「字段缺失」分开：字段缺失（平台改版类）一律 skip 不修复，
#     杜绝「假修复」；③ ioreg 前加 LC_ALL=C 消 stderr 噪音
# 文件：~/zopguard/guard.sh ｜ 日志：~/zopguard/guard.log ｜ 配置：~/zopguard/config.sh
#
# 通知模式（config.sh 里 NOTIFY_TYPE）：
#   feishu_webhook —— 飞书群机器人 Webhook（推荐，一个 URL 即可）
#   feishu_app     —— 飞书应用凭证（app_id / app_secret / chat_id）
#
# v1.2 平台自查配置（config.sh，可选；不配则跳过平台自查、只做进程检查）：
#   ZOPT_TOKEN —— ZopToken 控制台 token（查本机设备状态用）
#   ZOPT_GID   —— 设备组 ID（默认 69）
#   ZOPT_SN    —— 本机设备序列号（默认自动读取）
#
# v1.4 自动重登配置（config.sh）：
#   ZOPT_LOGIN_KEY —— ZopToken 登录密钥（客户端「密钥登录」用的 Key，形如 KEY-xxxx）
#   配了它：登出/槽位到期都会全自动恢复（API 直登，无需任何 GUI 权限）
set -u
export LC_ALL=C  # macOS sed 对 UTF-8 中文内容会报 illegal byte sequence，统一按字节处理

DIR="${ZOPGUARD_DIR:-$HOME/zopguard}"
LOG="$DIR/guard.log"
CFG="$DIR/config.sh"
STATE="$DIR/state"
# shellcheck disable=SC1090
[ -f "$CFG" ] && . "$CFG"
APP="${ZOPGUARD_APP:-ZopToken}"
APP_PATH="${ZOPGUARD_APP_PATH:-/Applications/ZopToken.app}"
MACHINE_NAME="${MACHINE_NAME:-$(hostname)}"
NOTIFY_TYPE="${NOTIFY_TYPE:-feishu_app}"
PLATFORM_API_GID="${ZOPT_GID:-69}"
COOLDOWN_SEC=720      # 两次自动修复最小间隔（秒）
DAILY_MAX=${ZOPGUARD_DAILY_MAX:-50}  # 每日自动修复上限（防重启风暴；v1.7 由 20 调至 50，可用环境变量覆盖）

AUTO_UPDATE_URL="${AUTO_UPDATE_URL:-}"  # 自更新源（config.sh 可配）：v1.6 起支持，格式 https://cdn.jsdelivr.net/gh/用户/仓库@分支/guard.sh
REMOTE_CMD_URL="${REMOTE_CMD_URL:-}"    # v1.8 中心命令文件（看板「一键重启」用）；仅自用机响应（有 license 的客户机不响应）
LIC="$DIR/license"                      # v1.7 授权文件：客户名|到期时间戳|HMAC签名；不存在=自用版（无限期）

# ---------- v1.8：中心远程重启命令（看板一键重启 → GitHub cmd/reboot.txt → 机端 3 分钟内执行） ----------
check_remote_cmd() {
  [ -z "$REMOTE_CMD_URL" ] && return 0
  [ -f "$LIC" ] && return 0          # 客户机不响应中心命令
  local body ts target
  body=$(curl -m 15 -s "$REMOTE_CMD_URL" 2>/dev/null)
  [ -z "$body" ] && {
    body=$(curl -m 15 -s "https://raw.githubusercontent.com/thuhien20086-maker/zopguard/main/cmd/reboot.txt" 2>/dev/null)
  }
  [ -z "$body" ] && return 0
  ts=$(echo "$body" | cut -d'|' -f1 | tr -d '[:space:]')
  target=$(echo "$body" | cut -d'|' -f2- | tr -d '[:space:]')
  case "$ts" in *[!0-9]*|"") return 0 ;; esac
  local last
  last=$(sget CMD_TS); last=${last:-0}
  [ "$ts" -le "$last" ] 2>/dev/null && return 0
  if [ "$target" = "all" ] || echo ",$target," | grep -q ",$MACHINE_NAME,"; then
    sput CMD_TS "$ts"
    log "remote-cmd: 收到重启指令（${ts}），60 秒后重启"
    notify "🔁 [$MACHINE_NAME] 收到看板远程重启指令，60 秒后自动重启。"
    ( sleep 60; osascript -e 'tell app "System Events" to restart' ) &
  fi
}

# ---------- v1.7：授权校验（license）+ 到期自毁 ----------
# license 行格式：客户名|到期时间戳|HMAC(客户名|到期时间戳，密钥)  密钥在 config.sh 的 ZOPGUARD_LICENSE_KEY
check_license() {
  [ -f "$LIC" ] || { echo "SELF"; return 0; }
  local cust exp sig calc now lk
  IFS='|' read -r cust exp sig < "$LIC" 2>/dev/null || { log "license: 文件损坏"; return 2; }
  lk="${ZOPGUARD_LICENSE_KEY:-}"
  [ -z "$lk" ] && { log "license: 缺 ZOPGUARD_LICENSE_KEY"; return 2; }
  calc=$(printf '%s|%s' "$cust" "$exp" | openssl dgst -sha256 -hmac "$lk" 2>/dev/null | awk '{print $NF}')
  [ "$calc" = "$sig" ] || { log "license: 签名无效（被篡改？）"; return 2; }
  now=$(date +%s)
  if [ $((exp - now)) -le 86400 ] && [ $((exp - now)) -gt 0 ]; then
    noted=$(sget LIC_NOTED)
    if [ "$noted" != "$exp" ]; then
      notify "⏳ [$MACHINE_NAME] 服务将于 $(date -r "$exp" '+%F') 到期，如需继续使用请及时续费。"
      sput LIC_NOTED "$exp"
    fi
  fi
  if [ "$now" -ge "$exp" ]; then
    log "license: 已到期（客户：$cust，$(date -r "$exp" '+%F')），执行自毁"
    notify "🚫 [$MACHINE_NAME] 服务已到期，守护已自动退出并卸载。如需继续使用请联系续费，续费后重新安装一条命令即可恢复。"
    self_destruct
    return 3
  fi
  echo "LIC($cust/$(date -r "$exp" '+%F'))"
  return 0
}

self_destruct() {
  # 只删自己的守护与配置，绝不碰客户的 ZopToken 客户端
  launchctl bootout "gui/$(id -u)/com.zopguard.guard" 2>/dev/null
  sleep 1
  rm -rf "$DIR"
  rm -f "$HOME/Library/LaunchAgents/com.zopguard.guard.plist"
  exit 0
}

# ---------- v1.6：自更新（每轮顺带查一次 VERSION，有新版本自动下载→校验→替换→重启） ----------
auto_update() {
  [ -z "$AUTO_UPDATE_URL" ] && return 0
  local base="${AUTO_UPDATE_URL%/guard.sh}"
  local ver_url="$base/VERSION"
  local remote_ver="" local_ver="" tmp=""
  # 双源尝试：主源拉不到就试 GitHub raw
  remote_ver=$(curl -m 15 -s "$ver_url" 2>/dev/null | tr -d '[:space:]')
  [ -z "$remote_ver" ] && {
    ver_url="https://raw.githubusercontent.com/$(echo "$AUTO_UPDATE_URL" | sed -E 's|https://cdn.jsdelivr.net/gh/([^/]+/[^/@]+)@[^/]+/.*|\1|')/main/VERSION"
    remote_ver=$(curl -m 15 -s "$ver_url" 2>/dev/null | tr -d '[:space:]')
  }
  [ -z "$remote_ver" ] && return 0
  local_ver=$(grep '^# zopguard-version:' "$0" 2>/dev/null | awk '{print $2}')
  [ "$remote_ver" = "$local_ver" ] && return 0
  # 有新版本：下载 → 多重校验 → 替换
  tmp="/tmp/zopguard-new.$$"
  curl -m 30 -s "$AUTO_UPDATE_URL" -o "$tmp" 2>/dev/null \
    || curl -m 30 -s "https://raw.githubusercontent.com/$(echo "$AUTO_UPDATE_URL" | sed -E 's|https://cdn.jsdelivr.net/gh/([^/]+/[^/@]+)@[^/]+/.*|\1|')/main/guard.sh" -o "$tmp" 2>/dev/null
  [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
  head -1 "$tmp" | grep -q '^#!/bin/bash' || { rm -f "$tmp"; return 0; }
  bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  grep -q "zopguard-version: $remote_ver" "$tmp" || { rm -f "$tmp"; return 0; }
  cp "$tmp" "$0" && chmod +x "$0" && rm -f "$tmp"
  log "auto-update: v$local_ver → v$remote_ver，重启守护"
  launchctl kickstart -k "gui/$(id -u)/com.long.zopguard" 2>/dev/null
  exit 0
}

# ---------- v1.2：app 路径兜底探测（配置没写对时也能找到） ----------
if [ ! -d "$APP_PATH" ]; then
  for _a in "$HOME/Desktop/ZopToken.app" "$HOME/Applications/ZopToken.app" "/Applications/ZopToken.app"; do
    if [ -d "$_a" ]; then APP_PATH="$_a"; break; fi
  done
fi

log() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null; }

# ---------- 状态键值读写 ----------
sget() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1; }
sput() { # key value
  local k="$1" v="$2" tmp="$STATE.tmp"
  if [ -f "$STATE" ]; then grep -v "^$k=" "$STATE" > "$tmp" 2>/dev/null; else : > "$tmp"; fi
  echo "$k=$v" >> "$tmp"
  mv "$tmp" "$STATE"
}

# ---------- 通知 ----------
esc1() { # 文本 → 单层 JSON 转义（webhook 模式用）
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}
esc2() { # 文本 → 双层 JSON 转义（app 模式用：content 是二次 JSON 字符串）
  local s="$1"
  s="${s//\\/\\\\\\\\}"
  s="${s//\"/\\\\\\\"}"
  printf '%s' "$s"
}
notify() { # $1 = 消息文本（单行）
  local text="$1" tt resp body
  [ "${ZOPGUARD_DRY:-0}" = "1" ] && { log "notify(dry): $text"; echo "[dry] $text"; return 0; }
  if [ "$NOTIFY_TYPE" = "feishu_webhook" ]; then
    [ -z "${FEISHU_WEBHOOK_URL:-}" ] && { log "notify: 未配置 FEISHU_WEBHOOK_URL"; return 1; }
    # v1.7 双通道：主群（客户群）必发；FEISHU_WEBHOOK_URL2（服务商监控群）有则同发
    for _wurl in "${FEISHU_WEBHOOK_URL:-}" "${FEISHU_WEBHOOK_URL2:-}"; do
      [ -z "$_wurl" ] && continue
      resp=$(curl -s -m 10 -X POST "$_wurl" -H "Content-Type: application/json" \
        --data "{\"msg_type\":\"text\",\"content\":{\"text\":\"$(esc1 "$text")\"}}")
      case "$resp" in
        *'\"code\":0'*|*'\"StatusCode\":0'*) log "notify sent: $text" ;;
        *) log "notify fail: $resp" ;;
      esac
    done
    return 0
  fi
  # feishu_app 模式
  [ -z "${FEISHU_APP_ID:-}" ] && { log "notify: 未配置飞书应用凭证"; return 1; }
  tt=$(curl -s -m 10 -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
       -H "Content-Type: application/json" \
       --data "{\"app_id\":\"$FEISHU_APP_ID\",\"app_secret\":\"$FEISHU_APP_SECRET\"}" \
       | sed -n 's/.*"tenant_access_token":"\([^"]*\)".*/\1/p')
  [ -z "$tt" ] && { log "notify: token 获取失败"; return 1; }
  body="{\"receive_id\":\"$FEISHU_CHAT_ID\",\"msg_type\":\"text\",\"content\":\"{\\\"text\\\":\\\"$(esc2 "$text")\\\"}\"}"
  resp=$(curl -s -m 10 -X POST "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id" \
       -H "Authorization: Bearer $tt" -H "Content-Type: application/json" \
       --data "$body")
  case "$resp" in
    *'"code":0'*) log "notify sent: $text"; return 0 ;;
    *) log "notify fail: $resp"; return 1 ;;
  esac
}

# ---------- v1.2：平台自查（假活检测） ----------
# stdout 一行描述；exit 0=平台正常 1=平台侧异常（按掉线处理） 2=不可判（不动手）
plat_check() {
  [ -z "${ZOPT_TOKEN:-}" ] && { echo "skip: no-token"; return 2; }
  local sn body st se found
  sn="${ZOPT_SN:-$(LC_ALL=C ioreg -l 2>/dev/null | sed -n 's/.*"IOPlatformSerialNumber" = "\([^"]*\)".*/\1/p' | head -1)}"
  [ -z "$sn" ] && sn="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | head -1)"
  [ -z "$sn" ] && { echo "skip: no-sn"; return 2; }
  body=$(curl -m 90 -s "https://www.zoptoken.com/api/console/device_group/devices?group_id=${PLATFORM_API_GID}&page=1&page_size=50" -H "token: $ZOPT_TOKEN" -H "User-Agent: zopguard/1.5" 2>/dev/null)
  [ -z "$body" ] && { echo "skip: net-unreachable"; return 2; }
  printf '%s' "$body" | jq -e '.code == 1' >/dev/null 2>&1 || { echo "skip: api-code"; return 2; }
  # v1.5：先判「设备是否在列表」；「在列但字段缺失」与「不在列表」分开处理——
  # 字段缺失（平台改版类）一律 skip 不修复，杜绝假修复（2026-09-18 教训）
  found=$(printf '%s' "$body" | jq -r --arg sn "$sn" '[.data.list[] | select(.sn==$sn)] | length' 2>/dev/null | head -1)
  case "$found" in
    ''|*[!0-9]*) echo "skip: jq-parse"; return 2 ;;
    '0') echo "unhealthy: not-listed(sn=$sn)"; return 1 ;;
  esac
  st=$(printf '%s' "$body" | jq -r --arg sn "$sn" '.data.list[] | select(.sn==$sn) | .state // empty' 2>/dev/null | head -1)
  if [ -z "$st" ]; then echo "skip: state-missing"; return 2; fi
  se=$(printf '%s' "$body" | jq -r --arg sn "$sn" '.data.list[] | select(.sn==$sn) | .slot_expire_time // empty' 2>/dev/null | head -1)
  if [ "$st" != "healthy" ] || [ "$se" = "0" ]; then
    echo "unhealthy: state=$st slot_expire=$se"; return 1
  fi
  echo "ok: $st"; return 0
}

# ---------- v1.4：API 直登（恢复设备槽位，零 GUI） ----------
# 平台槽位被释放（登出/到期）时：
#   1) keyLogin 用登录密钥换用户 token
#   2) device/init 带本机 SN+名+CPU 重新挂槽位 → 平台翻 healthy
# 返回 0=槽位已恢复；1=失败（下轮冷却后再试）。
api_relogin() {
  local utok resp code sn name cpu
  [ -z "${ZOPT_LOGIN_KEY:-}" ] && { log "api_relogin: 未配置 ZOPT_LOGIN_KEY"; return 1; }
  sn="${ZOPT_SN:-$(LC_ALL=C ioreg -l 2>/dev/null | sed -n 's/.*"IOPlatformSerialNumber" = "\([^"]*\)".*/\1/p' | head -1)}"
  [ -z "$sn" ] && sn="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | head -1)"
  [ -z "$sn" ] && { log "api_relogin: 取不到 SN"; return 1; }
  name="${MACHINE_NAME:-$(hostname)}"
  cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
  # 1) keyLogin（无需控制台 token，只需登录密钥 + UA）
  resp=$(curl -m 10 -s -X POST "https://www.zoptoken.com/api/user/keyLogin" \
    -H "User-Agent: zopguard/1.5" -H "Content-Type: application/json" \
    --data "{\"api_key\":\"$ZOPT_LOGIN_KEY\"}" 2>/dev/null)
  utok=$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$utok" ]; then
    log "api_relogin: keyLogin 失败（resp 前 80 字: $(printf '%s' "$resp" | head -c 80)）"
    return 1
  fi
  # 2) init 挂槽位
  resp=$(curl -m 10 -s -X POST "https://www.zoptoken.com/api/device/init" \
    -H "token: $utok" -H "User-Agent: zopguard/1.5" -H "Content-Type: application/json" \
    --data "{\"sn\":\"$sn\",\"name\":\"$name\",\"cpu\":\"$cpu\"}" 2>/dev/null)
  code=$(printf '%s' "$resp" | sed -n 's/.*"code":\([0-9]*\).*/\1/p' | head -1)
  if [ "$code" != "1" ]; then
    log "api_relogin: init 失败（$resp 前 120 字）"
    return 1
  fi
  log "api_relogin: init ok（sn=$sn）"
  return 0
}

# ---------- 核心：检查 & 修复 ----------
check_and_repair() {
  local now last cnt today cd_date noted reason="" pmsg pv
  # v1.7 授权校验（客户机：到期自动自毁退出；自用机无 license 正常放行）
  check_license >/dev/null 2>&1 || return 1
  now=$(date +%s)
  today=$(date +%F)
  last=$(sget LAST_REPAIR); last=${last:-0}
  cnt=$(sget COUNT); cnt=${cnt:-0}
  cd_date=$(sget COUNT_DATE)
  if [ "$cd_date" != "$today" ]; then cnt=0; sput COUNT_DATE "$today"; sput COUNT 0; fi

  # ① 进程检查 + 平台自查
  if pgrep -x "$APP" >/dev/null 2>&1; then
    pmsg=$(plat_check); pv=$?
    if [ "$pv" = "1" ]; then
      reason="假活（$pmsg）"
      log "plat-unhealthy: $pmsg → 按掉线处理"
    else
      log "ok: $APP 运行中（$pmsg）"
      echo "RUNNING"
      auto_update
      check_remote_cmd
      return 0
    fi
  else
    reason="进程未运行"
  fi

  # ② 冷却 / 日上限
  if [ $((now - last)) -lt "$COOLDOWN_SEC" ]; then
    log "abnormal($reason) 但冷却中（$((${COOLDOWN_SEC} - now + last))s 后可再修）"
    echo "ABNORMAL_COOLDOWN"
    return 0
  fi
  if [ "$cnt" -ge "$DAILY_MAX" ]; then
    noted=$(sget LIMIT_NOTED)
    if [ "$noted" != "$today" ]; then
      notify "⚠️ [$MACHINE_NAME] ZopToken 反复异常：今日已自动修复 $cnt 次达上限，暂停自动修复，请人工检查。"
      sput LIMIT_NOTED "$today"
    fi
    echo "LIMIT"
    return 0
  fi

  # ③ 修复：API 直登（恢复槽位）→ 退出→重开 → 轮询平台 healthy → 汇报
  local t0; t0=$(date '+%F %T')
  log "repair: $reason，执行 API直登+退出→重开（app=$APP_PATH）"
  # v1.4：先恢复平台槽位（配了登录 Key 才做），客户端重开后才会静默重连
  local relogin_rc=1
  if [ -n "${ZOPT_LOGIN_KEY:-}" ]; then
    api_relogin; relogin_rc=$?
  fi
  pkill -x "$APP" 2>/dev/null
  sleep 2
  pkill -9 -x "$APP" 2>/dev/null
  sleep 1
  if ! open "$APP_PATH" 2>>"$LOG"; then open -b "com.zoptoken.-" 2>>"$LOG" || true; fi
  # 轮询等待进程出现（最多 60 秒，每步 5 秒；ZOPGUARD_POLL_STEP 可调）
  local i ok=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep "${ZOPGUARD_POLL_STEP:-5}"
    if pgrep -x "$APP" >/dev/null 2>&1; then ok=1; break; fi
  done
  # v1.4：进程起来后再轮询平台确认 healthy（最多 60 秒，每步 5 秒）
  local plat_ok=0 pmsg2=""
  if [ "$ok" = "1" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 5
      pmsg2=$(plat_check); pv=$?
      if [ "$pv" = "0" ]; then plat_ok=1; break; fi
    done
  fi
  if [ "$ok" = "1" ] && [ "$plat_ok" = "1" ]; then
    notify "✅ [$MACHINE_NAME] $t0 检测到 ZopToken 异常（$reason），已自动恢复：平台槽位重新挂载 + 客户端重启，当前平台 healthy、进程运行中。"
    log "repair ok（平台 healthy，$t0）"
    echo "REPAIRED_OK"
  elif [ "$ok" = "1" ]; then
    if [ "$relogin_rc" = "0" ]; then
      notify "⚠️ [$MACHINE_NAME] $t0 ZopToken 异常（$reason）：槽位已恢复、客户端已重启，但平台侧 60 秒内未确认 healthy（$pmsg2），下轮自动复查。"
    else
      notify "⚠️ [$MACHINE_NAME] $t0 ZopToken 异常（$reason）：客户端已重启，但 API 直登失败（可能登录密钥失效或平台异常），下轮自动复查，如仍异常请人工看看。"
    fi
    log "repair half（$t0，$pmsg2）"
    echo "REPAIRED_HALF"
  else
    notify "⚠️ [$MACHINE_NAME] $t0 ZopToken 异常（$reason）已自动重启，60 秒内未确认进程恢复（可能启动慢或异常），下轮自动复查，如仍异常请人工看看。"
    log "repair failed（$t0）"
    echo "REPAIRED_FAIL"
  fi
  sput LAST_REPAIR "$now"
  cnt=$((cnt + 1)); sput COUNT "$cnt"
}

# ---------- 自检（部署时跑一次） ----------
selftest() {
  echo "== zopguard 自检 v1.8 =="
  echo "机器名: $MACHINE_NAME"
  echo "每日修复上限: $DAILY_MAX 次 / 冷却 ${COOLDOWN_SEC}s"
  if pgrep -x "$APP" >/dev/null 2>&1; then
    echo "ZopToken 进程: 运行中 ✓"
  else
    echo "ZopToken 进程: 未运行（下个周期将自动拉起）"
  fi
  echo "app 路径: $APP_PATH $([ -d "$APP_PATH" ] && echo '存在 ✓' || echo '不存在 ✗')"
  echo "登录密钥: $([ -n "${ZOPT_LOGIN_KEY:-}" ] && echo "已配置（${ZOPT_LOGIN_KEY:0:8}…）✓ 登出/槽位到期自动 API 直登恢复" || echo "未配置（登出后无法自动重登，请补 ZOPT_LOGIN_KEY）")"
  echo "平台自查: $(plat_check) (exit=$?)"
  echo "自更新: $([ -n "$AUTO_UPDATE_URL" ] && echo "已配置 ✓（$AUTO_UPDATE_URL）" || echo "未配置（升级需手动）")"
  echo "授权: $([ -f "$LIC" ] && echo "客户机（$(check_license)）" || echo "自用版（无限期）")"
  echo "launchd: $(launchctl list 2>/dev/null | grep -qi zopguard && echo '已加载 ✓' || echo '未加载')"
  echo "日志: $LOG"
  notify "🟢 [$MACHINE_NAME] zopguard 自愈守护 v1.8 已部署：进程掉线/平台假活自动「退出重开」，登录态掉线自动「API 直登恢复」，版本升级自动「自更新」，全过程汇报到本渠道。"
  echo "（自检消息已发送，请确认收到）"
}

if [ "${1:-run}" = "--selftest" ]; then
  selftest
  exit 0
fi

# ---------- 单实例锁（仅 run 模式；macOS 无 flock，用 mkdir 原子性） ----------
mkdir -p "$DIR" 2>/dev/null
LOCK="$DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 已存在：并发运行则直接退出；陈旧锁（>10 分钟残留）清理后重试一次
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

check_and_repair

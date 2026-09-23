#!/bin/bash
# zopguard —— ZopToken 自愈守护 v1.18（通用版）
# zopguard-version: 1.19
# 每 3 分钟由 launchd 调用：
#   · 检测 ZopToken 进程，异常时自动「退出→重开」
#   · v1.2 平台判据：进程活着但平台侧状态异常（假活/掉线）也会自动修复
#   · v1.4 API 直登：登录态掉线（登出/槽位到期）时用登录密钥直接调平台接口
#     恢复设备槽位，再重启客户端（客户端静默重连进主界面），零 GUI、零权限
#   · v1.5（2026-09-18）：① 每日修复上限 12→20；② 平台判据加固——
#     「设备不在列表」与「字段缺失」分开：字段缺失（平台改版类）一律 skip 不修复，
#     杜绝「假修复」；③ ioreg 前加 LC_ALL=C 消 stderr 噪音
#   · v1.9（2026-09-19）：每日一次「深度重启」——借当天首次掉线窗口，
#     彻底断开旧 TCP 连接（多等 8 秒）再重开客户端；当天不掉线则不触发
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
  target=$(echo "$body" | cut -d'|' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')  # v1.10：只去首尾，保留机器名内部空格
  case "$ts" in *[!0-9]*|"") return 0 ;; esac
  local last
  last=$(sget CMD_TS); last=${last:-0}
  [ "$ts" -le "$last" ] 2>/dev/null && return 0
  if [ "$target" = "all" ] || echo ",$target," | grep -Fq ",$MACHINE_NAME,"; then
    sput CMD_TS "$ts"
    log "remote-cmd: 收到重启指令（${ts}），60 秒后重启"
    notify "🔁 [$MACHINE_NAME] 收到看板远程重启指令，60 秒后自动重启。"
    # 优先 sudo shutdown（launchd 会话下可靠）；AUTOLOGIN_PASS 没进 config 时退回 osascript（GUI 会话）
    ( trap - EXIT   # v1.13：清除继承的锁释放 trap，防误删活锁
      sleep 60
      if [ -n "${AUTOLOGIN_PASS:-}" ]; then
        if ! printf '%s\n' "$AUTOLOGIN_PASS" | sudo -S shutdown -r now 2>/dev/null; then
          log "remote-cmd: sudo 重启失败，退回 osascript"
          notify "⚠️ [$MACHINE_NAME] 远程重启 sudo 失败（密码失效？），已尝试 GUI 方式重启。"
          osascript -e 'tell app "System Events" to restart' 2>/dev/null
        fi
      else
        osascript -e 'tell app "System Events" to restart' 2>/dev/null || notify "⚠️ [$MACHINE_NAME] 远程重启失败（无密码且 GUI 未授权），请人工重启。"
      fi ) &
  fi
}

# ---------- v1.7：授权校验（license）+ 到期自毁 ----------
# license 行格式：客户名|到期时间戳|HMAC(客户名|到期时间戳，密钥)  密钥在 config.sh 的 ZOPGUARD_LICENSE_KEY
check_license() {
  [ -f "$LIC" ] || { echo "SELF"; return 0; }
  local cust exp sig calc now lk
  IFS='|' read -r cust exp sig < "$LIC" 2>/dev/null || cust=""
  # v1.10：字段数不齐/为空 → 文件损坏，降级按自用版继续守护并告警（防静默停摆）
  if [ -z "$cust" ] || [ -z "$exp" ] || [ -z "$sig" ]; then
    noted=$(sget LIC_BROKEN_NOTED)
    if [ "$noted" != "1" ]; then
      notify "⚠️ [$MACHINE_NAME] 授权文件损坏，已临时按自用版继续守护，请人工检查（不影响 ZopToken 保护）。"
      sput LIC_BROKEN_NOTED 1
    fi
    log "license: 文件损坏，降级自用版守护"
    echo "BROKEN"
    return 0
  fi
  lk="${ZOPGUARD_LICENSE_KEY:-}"
  [ -z "$lk" ] && { log "license: 缺 ZOPGUARD_LICENSE_KEY，降级自用版守护"; echo "BROKEN-NOKEY"; return 0; }
  calc=$(printf '%s|%s' "$cust" "$exp" | openssl dgst -sha256 -hmac "$lk" 2>/dev/null | awk '{print $NF}')
  if [ "$calc" != "$sig" ]; then
    noted=$(sget LIC_BROKEN_NOTED)
    if [ "$noted" != "1" ]; then
      notify "⚠️ [$MACHINE_NAME] 授权签名无效（可能被篡改或密钥不匹配），已临时按自用版继续守护，请人工检查。"
      sput LIC_BROKEN_NOTED 1
    fi
    log "license: 签名无效，降级自用版守护"
    echo "BROKEN-SIG"
    return 0
  fi
  now=$(date +%s)
  # v1.11：时钟回拨防护（license 到期判定用单调时间，防回拨复活）
  local lm; lm=$(sget LAST_SEEN_TIME); lm=${lm:-0}
  [ "$now" -lt "$lm" ] 2>/dev/null && now=$lm
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
  # v1.10：先删文件再 bootout——bootout 会 SIGTERM 本进程，若先 bootout 则删文件永远执行不到
  # v1.17：license 先备份到 DIR 外；bootout 失败（label/域不符）时恢复 license + 告警下轮重试，
  #        否则到期客户机永久转自用版（无 license 降级放行）
  cp -f "$DIR/license" "$TMPDIR/zopguard-lic-backup" 2>/dev/null
  rm -rf "$DIR"
  rm -f "$HOME/Library/LaunchAgents/com.zopguard.guard.plist"
  ( trap - EXIT; sleep 3; launchctl bootout "gui/$(id -u)/com.zopguard.guard" 2>/dev/null
    sleep 1
    if launchctl list 2>/dev/null | grep -q com.zopguard.guard; then
      # bootout 失败：恢复 license，下轮重试（不静默转自用版）
      mkdir -p "$DIR" && cp -f "$TMPDIR/zopguard-lic-backup" "$DIR/license" 2>/dev/null
    fi ) &
  exit 3   # v1.13：到期自毁以非零码退出（return 3 契约可达）
}

# ---------- v1.6：自更新（每轮顺带查一次 VERSION，有新版本自动下载→校验→替换→重启） ----------
auto_update() {
  [ -z "$AUTO_UPDATE_URL" ] && return 0
  local base="${AUTO_UPDATE_URL%/guard.sh}"
  local ver_url="$base/VERSION"
  local remote_ver="" local_ver="" tmp=""
  # 双源尝试：主源拉不到就试 GitHub raw
  remote_ver=$(curl -m 15 -s "$ver_url" 2>/dev/null | tr -d '[:space:]')
  # v1.17：剥离 v 前缀 + 校验格式（旧逻辑 v1.17 会被版本比较误判「不高于」→ 自更新永久失效）
  remote_ver=$(printf '%s' "$remote_ver" | sed -E 's/^[vV]//; s/[^0-9.].*$//')
  case "$remote_ver" in ''|*[!0-9.]*|*..*) remote_ver="";; esac
  [ -z "$remote_ver" ] && {
    ver_url="https://raw.githubusercontent.com/$(echo "$AUTO_UPDATE_URL" | sed -E 's|https://cdn.jsdelivr.net/gh/([^/]+/[^/@]+)@[^/]+/.*|\1|')/main/VERSION"
    remote_ver=$(curl -m 15 -s "$ver_url" 2>/dev/null | tr -d '[:space:]')
    remote_ver=$(printf '%s' "$remote_ver" | sed -E 's/^[vV]//; s/[^0-9.].*$//')
    case "$remote_ver" in ''|*[!0-9.]*|*..*) remote_ver="";; esac
  }
  [ -z "$remote_ver" ] && return 0
  local_ver=$(grep '^# zopguard-version:' "$0" 2>/dev/null | awk '{print $2}')
  [ "$remote_ver" = "$local_ver" ] && return 0
  # v1.13：只升不降 + 「已尝试版本」闸——用 awk 数值比较（POSIX 安全，老 macOS 无 sort -V）
  ver_cmp() { # 1=$1>$2 0=其他；按点分数字段逐段比较
    printf '%s\n%s\n' "$1" "$2" | awk -F. '
      NR==1{split($0,a,FS)}
      NR==2{split($0,b,FS); n=NF; if(length(a)>n)n=length(a);
        for(i=1;i<=n;i++){av=a[i]+0; bv=b[i]+0;
          if(av>bv){print 1;exit}
          if(av<bv){print 0;exit}}
        print 0; exit}'
  }
  if [ "$(ver_cmp "$remote_ver" "$local_ver")" != "1" ]; then
    log "auto-update: 远端版本 $remote_ver 不高于本地 $local_ver，忽略"
    return 0
  fi
  last_tried=$(sget UPD_LAST_VER)
  [ "$last_tried" = "$remote_ver" ] && return 0
  # 有新版本：下载 → 多重校验 → 替换
  tmp="/tmp/zopguard-new.$$"
  curl -m 30 -s "$AUTO_UPDATE_URL" -o "$tmp" 2>/dev/null \
    || curl -m 30 -s "https://raw.githubusercontent.com/$(echo "$AUTO_UPDATE_URL" | sed -E 's|https://cdn.jsdelivr.net/gh/([^/]+/[^/@]+)@[^/]+/.*|\1|')/main/guard.sh" -o "$tmp" 2>/dev/null
  [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
  head -1 "$tmp" | grep -q '^#!/bin/bash' || { rm -f "$tmp"; return 0; }
  bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  grep -q "^# zopguard-version: ${remote_ver}$" "$tmp" || { rm -f "$tmp"; return 0; }
  cp "$tmp" "$0.new" && mv "$0.new" "$0" && chmod +x "$0" && rm -f "$tmp"
  if [ -f "$tmp" ] || [ -f "$0.new" ]; then
    # v1.16：替换失败（cp/mv/chmod 任一环节断）→ 清残留 + 记日志，下轮重试；
    # 旧逻辑无条件写 UPD_LAST_VER 会把「尝试过但没换成」标成「已尝试」，版本闸永远拦死自更新（2号机事件）
    rm -f "$tmp" "$0.new"
    log "auto-update: 替换失败，下轮重试"
    return 0
  fi
  sput UPD_LAST_VER "$remote_ver"
  log "auto-update: v$local_ver → v$remote_ver（下轮起生效，本轮 exit 释放锁）"
  notify "🔄 [$MACHINE_NAME] 守护已自动升级 v$local_ver → v$remote_ver（下轮巡检起生效）。"
  # v1.10：不再 kickstart 自杀（SIGKILL 会让锁残留 30 分钟死窗）；下个 StartInterval 自然用新版本
  exit 0
}

# ---------- v1.2：app 路径兜底探测（配置没写对时也能找到） ----------
if [ ! -d "$APP_PATH" ]; then
  for _a in "$HOME/Desktop/ZopToken.app" "$HOME/Applications/ZopToken.app" "/Applications/ZopToken.app"; do
    if [ -d "$_a" ]; then APP_PATH="$_a"; break; fi
  done
fi

log() { # v1.10：超 5MB 轮转，防日志无限增长
  if [ -f "$LOG" ]; then
    local sz; sz=$(wc -c < "$LOG" 2>/dev/null | tr -d ' '); sz=${sz:-0}
    if [ "${sz:-0}" -gt 5242880 ] 2>/dev/null; then mv "$LOG" "$LOG.1" 2>/dev/null; fi
  fi
  echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || echo "[$(date '+%F %T')] $*" >&2
}

# ---------- 状态键值读写 ----------
sget() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1; }
sput() { # key value
  local k="$1" v="$2" tmp="$STATE.tmp.$$"   # v1.10：tmp 带 PID，防并发实例互相截断
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
  [ -z "${FEISHU_APP_SECRET:-}" ] && { log "notify: 缺 FEISHU_APP_SECRET（set -u 防护）"; return 1; }
  [ -z "${FEISHU_CHAT_ID:-}" ] && { log "notify: 缺 FEISHU_CHAT_ID（set -u 防护）"; return 1; }
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
  local sn body st se found page total nlist code
  sn="${ZOPT_SN:-$(LC_ALL=C ioreg -l 2>/dev/null | sed -n 's/.*IOPlatformSerialNumber.*=.*"\([^"]*\)".*/\1/p' | head -1)}"
  [ -z "$sn" ] && sn="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | head -1)"
  [ -z "$sn" ] && { echo "skip: no-sn"; return 2; }
  # v1.11：jq 缺失粗判模式——macOS 出厂不带 jq（客户机未必装），没有 jq 时用 grep 兜底
  if ! command -v jq >/dev/null 2>&1; then
    local cpage cnlist
    cpage=1
    while [ "$cpage" -le 10 ]; do
      body=$(curl -m 90 -s "https://www.zoptoken.com/api/console/device_group/devices?group_id=${PLATFORM_API_GID}&page=$cpage&page_size=50" -H "token: $ZOPT_TOKEN" -H "User-Agent: zopguard/1.13" 2>/dev/null)
      [ -z "$body" ] && { echo "skip: net-unreachable"; return 2; }
      code=$(printf '%s' "$body" | awk 'match($0,/"code":[0-9]+/){print substr($0,RSTART+7,RLENGTH-7); exit}')
      [ "$code" != "1" ] && { echo "skip: api-code"; return 2; }
      if printf '%s' "$body" | grep -Fq "\"sn\":\"$sn\""; then
        # v1.17：设备级判定——用 awk 切出本机 SN 所在的对象片段，state/slot 只在本机片段内检查
        # （旧逻辑对整页 50 台 grep：同页任一台健康→本机漏检，任一台停费→本机被误杀）
        local devseg
        devseg=$(printf '%s' "$body" | awk -v sn="$sn" 'BEGIN{RS="},"} index($0,"\"sn\":\"" sn "\"") {print $0 "}"}' | head -1)
        [ -z "$devseg" ] && { echo "unhealthy: not-listed(coarse)"; return 1; }
        if printf '%s' "$devseg" | grep -Fq '"slot_expire_time":"0"'; then
          echo "unhealthy: slot-expired(coarse)"; return 1
        fi
        if ! printf '%s' "$devseg" | grep -Fq '"state":"healthy"'; then
          echo "unhealthy: state-bad(coarse)"; return 1
        fi
        echo "ok: listed(coarse)"; return 0
      fi
      cnlist=$(printf '%s' "$body" | grep -o '"sn":' | wc -l | tr -d ' ')
      [ "${cnlist:-0}" -ge 50 ] 2>/dev/null || break
      cpage=$((cpage + 1))
    done
    echo "unhealthy: not-listed(coarse)"; return 1
  fi
  # v1.10：翻页直到找到本机 SN（>50 台设备的组不再误判 not-listed）
  page=1; found="0"
  while [ "$page" -le 10 ]; do
    body=$(curl -m 90 -s "https://www.zoptoken.com/api/console/device_group/devices?group_id=${PLATFORM_API_GID}&page=$page&page_size=50" -H "token: $ZOPT_TOKEN" -H "User-Agent: zopguard/1.10" 2>/dev/null)
    [ -z "$body" ] && { echo "skip: net-unreachable"; return 2; }
    printf '%s' "$body" | jq -e '.code == 1' >/dev/null 2>&1 || { echo "skip: api-code"; return 2; }
    found=$(printf '%s' "$body" | jq -r --arg sn "$sn" '[.data.list[] | select(.sn==$sn)] | length' 2>/dev/null | head -1)
    case "$found" in
      ''|*[!0-9]*) echo "skip: jq-parse"; return 2 ;;
      '1') break ;;
    esac
    total=$(printf '%s' "$body" | jq -r '.data.total // 0' 2>/dev/null | head -1)
    nlist=$(printf '%s' "$body" | jq -r '.data.list | length' 2>/dev/null | head -1)
    # v1.11：total 字段缺失时按「本页满 50 条」继续翻页（平台未必返回 total）
    [ "${total:-0}" -gt $((page * 50)) ] 2>/dev/null && { page=$((page + 1)); continue; }
    [ "${nlist:-0}" -ge 50 ] 2>/dev/null && { page=$((page + 1)); continue; }
    break
  done
  if [ "$found" != "1" ]; then echo "unhealthy: not-listed(sn=$sn)"; return 1; fi
  # v1.5：先判「设备是否在列表」；「在列但字段缺失」与「不在列表」分开处理——
  # 字段缺失（平台改版类）一律 skip 不修复，杜绝假修复（2026-09-18 教训）
  st=$(printf '%s' "$body" | jq -r --arg sn "$sn" '.data.list[] | select(.sn==$sn) | .state // empty' 2>/dev/null | head -1)
  if [ -z "$st" ]; then echo "skip: state-missing"; return 2; fi
  se=$(printf '%s' "$body" | jq -r --arg sn "$sn" '.data.list[] | select(.sn==$sn) | .slot_expire_time // empty' 2>/dev/null | head -1)
  # v1.15：state 才是主判据——state 坏立即修（offline 设备平台不返回 slot_expire_time，
  # 旧逻辑 se-missing 一律 skip 会把真掉线全漏掉）；se-missing 豁免仅在 state=healthy 时生效（防平台改版误修）
  if [ "$st" != "healthy" ]; then
    echo "unhealthy: state=$st slot_expire=$se"; return 1
  fi
  if [ -z "$se" ]; then echo "skip: se-missing"; return 2; fi
  if [ "$se" = "0" ]; then
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
  sn="${ZOPT_SN:-$(LC_ALL=C ioreg -l 2>/dev/null | sed -n 's/.*IOPlatformSerialNumber.*=.*"\([^"]*\)".*/\1/p' | head -1)}"
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
  local now last cnt today cd_date noted reason="" pmsg pv maxt
  # v1.7 授权校验（客户机：到期自动自毁退出；自用机无 license 正常放行）
  check_license >/dev/null 2>&1 || return 1
  # v1.18：机器永不睡——每轮确保 caffeinate 全防在跑（-d 显示器 -i 空闲 -m 磁盘 -u 用户活跃 -s 系统睡眠；免 sudo；重启后自动恢复）
  pgrep -x caffeinate >/dev/null 2>&1 || { nohup caffeinate -diumsu >/dev/null 2>&1 & }
  # v1.17：自更新与远程命令无条件执行（旧逻辑只在健康分支跑——坏机器永远收不到新版和一键重启）
  auto_update
  check_remote_cmd
  now=$(date +%s)
  today=$(date +%F)
  # v1.10 时钟回拨防护：now 小于历史最大值时按历史最大值算（防冷却失效/授权复活）
  maxt=$(sget LAST_SEEN_TIME); maxt=${maxt:-0}
  if [ "$now" -lt "$maxt" ] 2>/dev/null; then log "clock-rollback: $now < $maxt，按单调时间处理"; now=$maxt; fi
  sput LAST_SEEN_TIME "$now"   # v1.13：回写修正后的值（用真实时钟会击穿单调地板）
  last=$(sget LAST_REPAIR); last=${last:-0}
  cnt=$(sget COUNT); cnt=${cnt:-0}
  cd_date=$(sget COUNT_DATE)
  # v1.10：每日重置合并为单次原子写（防中途被杀导致计数不清零）
  if [ "$cd_date" != "$today" ]; then
    cnt=0
    {
      grep -v -E '^(COUNT_DATE|COUNT)=' "$STATE" > "$STATE.tmp.$$" 2>/dev/null || : > "$STATE.tmp.$$"
      echo "COUNT_DATE=$today" >> "$STATE.tmp.$$"
      echo "COUNT=0" >> "$STATE.tmp.$$"
      mv "$STATE.tmp.$$" "$STATE"
    }
  fi

  # ① 进程检查 + 平台自查
  if pgrep -x "$APP" >/dev/null 2>&1; then
    pmsg=$(plat_check); pv=$?
    if [ "$pv" = "1" ]; then
      reason="假活（$pmsg）"
      log "plat-unhealthy: $pmsg → 按掉线处理"
    else
      log "ok: $APP 运行中（$pmsg）"
      echo "RUNNING"
      return 0
    fi
  else
    reason="进程未运行"
  fi

  # v1.18：3 天整机重启——距上次整机重启 ≥3 天时，借本次掉线窗口直接重启整机
  # （防长时间开机客户端软件失灵；3 天内只触发一次；重启后 launchd 自动拉起一切）
  # v1.19：移到冷却/上限检查之前——整机重启是最终手段，修复达上限/冷却中都不该挡它
  local rb_ts rb_days
  rb_ts=$(sget LAST_REBOOT_TS); rb_ts=${rb_ts:-0}
  rb_days=$(( (now - rb_ts) / 86400 ))
  if [ "$rb_days" -ge 3 ] && [ "$(sget REBOOT_NOTED)" != "$today" ]; then
    log "3天整机重启：距上次整机重启 $rb_days 天，借本次掉线窗口执行"
    sput LAST_REBOOT_TS "$now"
    sput REBOOT_NOTED "$today"
    notify "🔁 [$MACHINE_NAME] 已连续运行 $rb_days 天，借本次掉线窗口自动整机重启（防长时间开机失灵），约 1 分钟后重启。"
    ( trap - EXIT; sleep 60; sudo -n shutdown -r now 2>/dev/null || osascript -e 'tell app "System Events" to restart' 2>/dev/null ) &
    exit 0
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
  # v1.9：每日一次「深度重启」——借当天首次掉线窗口，彻底断开旧 TCP 连接再重开；
  #       当天不掉线则不触发（此函数只在检测到异常时进入）
  local deep=0
  if [ "$(sget DEEP_RESTART_DAY)" != "$(date +%F)" ]; then
    deep=1
    sput DEEP_RESTART_DAY "$(date +%F)"
  fi
  pkill -x "$APP" 2>/dev/null
  sleep 2
  pkill -9 -x "$APP" 2>/dev/null
  sleep 1
  if [ "$deep" = "1" ]; then
    log "deep-restart: 今日首次掉线窗口，深度重启客户端（多等 8 秒让旧连接完全断开）"
    sleep 8
  fi
  if ! open "$APP_PATH" 2>>"$LOG"; then
    if ! open -b "com.zoptoken.-" 2>>"$LOG"; then
      # v1.11：两条路都失败 → 一次性告警（不再默默重试到上限）
      local af; af=$(sget APP_FAIL_NOTED)
      if [ "$af" != "1" ]; then
        notify "⚠️ [$MACHINE_NAME] ZopToken 客户端无法启动（路径 $APP_PATH 无效？），请人工检查 App 位置。"
        sput APP_FAIL_NOTED 1
      fi
    fi
  fi
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
      # v1.17：不可判（skip，pv=2）傻等 60 秒无意义——no-token/no-sn/网络不可达不会随重试变好
      [ "$pv" = "2" ] && { pmsg2="${pmsg2}(不可判)"; break; }
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
  echo "== zopguard 自检 v1.19 =="
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
  notify "🟢 [$MACHINE_NAME] zopguard 自愈守护 v1.19 已部署：进程掉线/平台假活自动「退出重开」，登录态掉线自动「API 直登恢复」，版本升级自动「自更新」，全过程汇报到本渠道。"
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
  # 已存在：并发运行则直接退出；陈旧锁（>30 分钟残留；修复最坏路径约 22 分钟）清理后重试一次
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
# v1.17：锁内写 pid 文件——EXIT trap 只删自己创建的锁（防睡眠>30min 后旧实例醒来误删新实例锁 → 双实例风暴）
echo "$$" > "$LOCK/pid" 2>/dev/null
trap 'if [ -f "$LOCK/pid" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; fi' EXIT

check_and_repair

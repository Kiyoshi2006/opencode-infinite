#!/usr/bin/env bash
# OpenCode Infinite for Linux: the Windows launcher's flow in bash.
# Egress WARP / TOR / PROXY / NONE, target IP hunt, probe, resume when a limit stops the chat.
# Needs: bash 4.3+, curl, node + opencode. Optional: warp-cli, tor, privoxy, jq (menus in other languages).
VERSION="linux-0.4.7"
REPO="https://gitlab.com/jekooo/opencode-infinite"
REPO_RAW="https://gitlab.com/jekooo/opencode-infinite/-/raw/main"

STATE_DIR="${OCI_STATE:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode-infinite}"
CONF="$STATE_DIR/config.env"
LOG="$STATE_DIR/launcher.log"
APP_DIR="$STATE_DIR/app"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
BIN_DIR="$HOME/.local/bin"
LIMIT_FLAG="$STATE_DIR/limit.flag"
OC_PIDS="$STATE_DIR/oc.pids"  # v0.3.3: PIDs of the opencode this launcher started, the only ones stop_opencode may kill
ROT_LOG="$STATE_DIR/rotations.log"
ASK_FLAG="$STATE_DIR/ask.flag"; ASK_LAST="$STATE_DIR/ask.last"  # v0.3.3: rate limit asks before rotating, at most once per 10 minutes
PATTERNS="$STATE_DIR/patterns.conf"
SELF="$(readlink -f "$0")"
ARGS=("$@")
# v0.3.3: three lists. rotate = usage limit and the like (rotates by itself), ask = rate limit (asks first), noop = never rotates (compaction, context, model).
# "Failed to drain Session" (a compaction error) no longer rotates. patterns.conf (rotate= / ask= / noop=, regex alternatives joined by |) overrides these
PAT_ROTATE_DEF='usage limit|out of usage|insufficient credits|payment required|ip (is )?blocked|blocked ip|403.*region|region.*403'
PAT_ASK_DEF='rate limit|rate_limit_exceeded|too many requests|status(Code)?[=: ]*429|HTTP 429'
PAT_NOOP_DEF='compaction|context length exceeded|context_length_exceeded|maximum context|model not found|invalid model|ProviderModelNotFound|content filter|content policy|content_policy'
OC_PAT="level=ERROR.*($PAT_ROTATE_DEF)"
ESC=$'\e'
PATH="$PATH:/usr/sbin:/sbin"  # tor and privoxy live here on Debian and Ubuntu
MARG=""
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- settings table
# key|group|type|default|label|help|options: enum a,b / num min:max / bool and text leave it empty
SETDEF=(
'OC_EGRESS_DEFAULT|Connection|enum|ASK|Egress|ASK = pick at each start. WARP, TOR, PROXY or NONE = used for OpenCode. System traffic stays direct.|ASK,WARP,TOR,PROXY,NONE'
# same keys as the Windows launcher; an OC_APP environment variable is the default of the path setting
'OC_MODE_DEFAULT|Connection|enum|CLI|Run mode|CLI = OpenCode in this terminal. DESKTOP = the OpenCode desktop app, closed and started again at each new IP. The probe and the opencode command always use the CLI.|CLI,DESKTOP'
'OC_OTHER_WINDOW|Connection|enum|OPEN|If already open|What a start does when OpenCode already runs from another launcher window. OPEN = open anyway. CLOSE = close that one first. ASK = ask. Auto never asks: it opens anyway.|OPEN,CLOSE,ASK'
"OC_APP|Connection|text|${OC_APP:-}|Desktop app path|Empty = /opt/OpenCode/ai.opencode.desktop, then ai.opencode.desktop on the PATH. Type - to clear.|"
'PROXY_PORT|Connection|num|40000|WARP proxy port|Local port of the WARP proxy.|1:65535'
'WARP_WAIT|Connection|num|20|WARP wait (s)|Seconds to wait after (re)connecting WARP.|1:120'
'WARP_CALL_TIMEOUT|Connection|num|15|warp-cli timeout (s)|Seconds a single warp-cli call may take.|5:300'
'TOR_SOCKS_PORT|Tor|num|9050|Tor SOCKS port|SOCKS port of the Tor the launcher starts. A Tor already on this port is reused.|1:65535'
'TOR_HTTP_PORT|Tor|num|8118|Tor HTTP bridge port|HTTP port of the built-in bridge OpenCode uses. Must be free or already a Tor bridge.|1:65535'
'TOR_AUTO_INSTALL|Tor|bool|1|Install Tor automatically|Install tor and privoxy with the package manager when they are missing.|'
'TOR_BOOTSTRAP_WAIT|Tor|num|120|Tor bootstrap wait (s)|Seconds to wait for Tor to finish bootstrapping.|30:900'
'PROXY_LIST_URL|Proxy list|text|https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=protocolipport&format=text|Proxy list source|URL or local file, any format. ip:port entries are picked out of it. Type - to clear.|'
'PROXY_LIST_MIN_BYTES|Proxy list|num|20|Minimum list size (bytes)|A downloaded list smaller than this is rejected. 0 = off.|0:100000000'
'PROXY_TRY_MAX|Proxy list|num|25|Proxies tried per pick|How many proxies to test before giving up.|1:500'
'PROXY_PROBE_TIMEOUT|Proxy list|num|8|Proxy test timeout (s)|Seconds a single proxy test may take.|1:120'
'PROXY_ROT_MAX|Proxy list|num|10|Burned proxies before Tor offer|Burned proxies in one hunt before PROXY mode offers Tor.|1:200'
'PROXY_API_CHECK|Proxy list|bool|0|Check the API host|A proxy must also reach the OpenCode API host.|'
'PROXY_API_CHECK_URL|Proxy list|text|https://api.opencode.ai/|API check URL|Host used by the API check. Type - to clear.|'
'AUTO_ROTATE|Rotation|bool|1|Automatic rotation|On: a limit gets a new IP and the chat resumes. Off: the menu decides.|'
'ROTATE_TRIES_MAX|Rotation|num|4|Rotation attempts|Attempts per round when the route is not up.|1:20'
'ROTATE_COOLDOWN|Rotation|num|10|Cooldown between attempts (s)|Seconds to wait between rotation tries. Cloudflare throttles rapid registrations.|0:300'
'IP_FIND_MAX|Rotation|num|0|Burned IPs allowed|IPs the probe may reject before giving up. 0 = no limit.|0:10000'
'TARGET_COUNTRY|Rotation|text||Target country|Keep asking for IPs until one is in this country, e.g. DE. Empty = any. Type - to clear.|'
'TARGET_PREFIX|Rotation|text||Target IP prefix|Keep asking until the IP starts with this, e.g. 104.28. Empty = not used. Type - to clear.|'
'TARGET_TRIES|Rotation|num|1|Max attempts per hunt|New IPs requested in one hunt. The hunt stops at this count.|1:100'
'TARGET_MINUTES|Rotation|num|15|Max minutes per hunt|The hunt stops after this many minutes.|1:240'
'TARGET_INTERVAL|Rotation|num|15|Seconds between attempts|Pause between two attempts, so Cloudflare is not hit too fast.|0:300'
'ON_CLOSE|Rotation|enum|ask|After OpenCode closes|ask = R, M or Q: R new IP and resume the chat, M menu, Q quit. quit = leave the launcher at once.|ask,quit'
'WATCH|Watcher|bool|0|Watch the log|Rotate when a fatal error appears while OpenCode runs.|'
'RESUME_MSG|Watcher|text|continue|Resume message|Sent automatically after a rotation.|'
'RESUME_AUTO|Watcher|bool|1|Unattended resume|The resume auto-approves tool permissions (opencode run --auto).|'
'RESUME_TIMEOUT|Watcher|num|90|Resume timeout (s)|Seconds before a silent resume counts as a dead IP.|10:900'
'RESUME_MODE|Watcher|enum|continue|Resume mode|continue = the resume message. custom = the custom text below.|continue,custom'
'RESUME_TEXT|Watcher|text||Custom resume text|Text sent when the resume mode is custom.|'
'PROBE|Probe|bool|0|Test every new IP|Send one cheap message through each candidate IP. Off by default: each probe uses the free quota.|'
'PROBE_MODEL|Probe|text||Probe model|Model used by the IP probe. Empty = the chat model.|'
'PROBE_BROKEN_MAX|Probe|num|3|Probe failures tolerated|Non-limit probe failures before the hunt stops and says the probe is broken.|1:50'
'UPDATE_CHECK|Updates|bool|1|Launcher self-update|Check GitLab for a newer launcher at every start.|'
'UPDATE_ASK|Updates|enum|ask|Update prompts|ask = offer newer versions at start. never = no checks and no prompts.|ask,never'
'OC_API_BASE|Updates|text|https://opencode.ai/update/api/latest|Release metadata URL|Where the newest opencode version is read from. npm is the fallback.|'
'OCUI_THEME|Appearance|enum|ocean|Color theme|Accent colors of the menus.|ocean,forest,sunset,mono,rainbow'
'OCUI_COLOR|Appearance|enum|auto|Colors|auto follows the terminal and NO_COLOR. on or off forces it.|auto,on,off'
'OCUI_ICONS|Appearance|enum|auto|Borders|auto = UTF-8 borders when the locale is UTF-8. unicode or emoji = UTF-8 borders. ascii = plain.|auto,emoji,unicode,ascii'
'OCUI_LANG|Appearance|enum|auto|Language|Language of the menus. auto follows LANG. Only the chosen file is downloaded.|auto,en,de,es,fr,it,pt,tr,ru'
'KEY_ROTATE|Shortcuts|key|R|Rotate key|Closed-OpenCode prompt: new IP and resume the chat. One letter.|'
'KEY_MENU|Shortcuts|key|M|Menu key|Closed-OpenCode prompt: open the menu. One letter.|'
'KEY_QUIT|Shortcuts|key|Q|Quit key|Closed-OpenCode prompt: quit. Ctrl+C always quits too. One letter.|'
'LOG_ENABLED|Logs|bool|1|Activity log|Record what the launcher does in launcher.log.|'
'LOG_MAX_KB|Logs|num|1024|Log size limit (KB)|The log is cut to its newest part when it grows past this.|64:10240'
'LOG_MASK_IP|Logs|bool|1|Hide IPs in reports|Public IP addresses are masked in the support report.|'
)
SK=(); SG=(); ST=(); SD=(); SL=(); SH=(); SO=()
for row in "${SETDEF[@]}"; do
  IFS='|' read -r k g t d l h o <<< "$row"
  SK+=("$k"); SG+=("$g"); ST+=("$t"); SD+=("$d"); SL+=("$l"); SH+=("$h"); SO+=("${o:-}")
done

# ---------------------------------------------------------------- config and log
cfg_get(){ if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -n "s/^$1=//p" "$CONF" | tail -n1; else printf '%s' "$2"; fi; }
# The .bat and the .exe read config.json from the same folder: a change made here goes there too.
cfg_set(){
  touch "$CONF"; { grep -v "^$1=" "$CONF"; printf '%s=%s\n' "$1" "$2"; } > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  [ -f "$STATE_DIR/config.json" ] && command -v python3 >/dev/null 2>&1 &&
    python3 -I -c 'import json,os,sys
p,k,v=sys.argv[1:4]
j=json.load(open(p,encoding="utf-8"))
s=j["settings"] if isinstance(j.get("settings"),dict) else j
s[k]=int(v) if v.lstrip("-").isdigit() else v
open(p+".tmp","w",encoding="utf-8").write(json.dumps(j,indent=2,ensure_ascii=False)+"\n")
os.replace(p+".tmp",p)' "$STATE_DIR/config.json" "$1" "$2" 2>/dev/null
  return 0
}
load_cfg(){
  local i k v
  for i in "${!SK[@]}"; do
    k=${SK[i]}; v=$(cfg_get "$k" "${SD[i]}")
    if [ "${ST[i]}" = num ] || [ "${ST[i]}" = bool ]; then [[ "$v" =~ ^[0-9]+$ ]] || v=${SD[i]}; fi
    printf -v "$k" '%s' "$v"
  done
  OC_REAL=$(cfg_get OC_REAL ""); OC_LINK=$(cfg_get OC_LINK ""); SETUP_DONE=$(cfg_get SETUP_DONE 0)
  # EGRESS is the route in use this run: the saved default, or NONE while the default is ASK (picked at start)
  OC_EGRESS_DEFAULT=$(cfg_get OC_EGRESS_DEFAULT "$(cfg_get EGRESS ASK)")
  case $OC_EGRESS_DEFAULT in ASK|WARP|TOR|PROXY|NONE) ;; *) OC_EGRESS_DEFAULT=ASK;; esac
  EGRESS=$OC_EGRESS_DEFAULT; [ "$EGRESS" = ASK ] && EGRESS=NONE
  # keys renamed in 0.3.0: an older config.env keeps its values
  ROTATE_TRIES_MAX=$(cfg_get ROTATE_TRIES_MAX "$(cfg_get ROTATE_TRIES "$ROTATE_TRIES_MAX")")
  [[ $ROTATE_TRIES_MAX =~ ^[0-9]+$ ]] || ROTATE_TRIES_MAX=4
  OCUI_THEME=$(cfg_get OCUI_THEME "$(cfg_get THEME "$OCUI_THEME")")
  load_patterns
  load_themes
}
# v0.3.3: pat_get <key> <default>: key missing = default, key present but empty = never matches
pat_get(){
  grep -q "^$1=" "$PATTERNS" 2>/dev/null || { printf '%s' "$2"; return 0; }
  local v; v=$(sed -n "s/^$1=//p" "$PATTERNS" | tail -n1 | tr -d '\r'); printf '%s' "${v:-a^}"
}
# patterns.conf: rotate=, ask=, noop=. Missing file or key, or a broken regex: the defaults
load_patterns(){
  PAT_ROTATE=$(pat_get rotate "$PAT_ROTATE_DEF"); PAT_ASK=$(pat_get ask "$PAT_ASK_DEF"); PAT_NOOP=$(pat_get noop "$PAT_NOOP_DEF")
  printf '' | grep -Eq "$PAT_ROTATE" 2>/dev/null; [ $? = 2 ] && { log 'patterns.conf: bad rotate regex, default used'; PAT_ROTATE=$PAT_ROTATE_DEF; }
  printf '' | grep -Eq "$PAT_ASK" 2>/dev/null; [ $? = 2 ] && { log 'patterns.conf: bad ask regex, default used'; PAT_ASK=$PAT_ASK_DEF; }
  printf '' | grep -Eq "$PAT_NOOP" 2>/dev/null; [ $? = 2 ] && { log 'patterns.conf: bad noop regex, default used'; PAT_NOOP=$PAT_NOOP_DEF; }
  OC_PAT="level=ERROR.*($PAT_ROTATE)"
}

log(){
  [ "$LOG_ENABLED" = 1 ] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
  if [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt $(( LOG_MAX_KB * 1024 )) ]; then tail -c $(( LOG_MAX_KB * 512 )) "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
}

# ---------------------------------------------------------------- language
declare -A TH TRMAP
# tx <english>: the translated label, English when the language file has no entry
tx(){ printf '%s' "${TRMAP[$1]:-$1}"; }
load_lang(){
  TRMAP=()
  local code=$OCUI_LANG
  if [ "$code" = auto ]; then code=${LC_ALL:-${LANG:-en}}; code=${code%%[_.@]*}; fi
  case $code in de|es|fr|it|pt|tr|ru) ;; *) return 0;; esac
  command -v jq >/dev/null || { log 'jq missing: menus stay in English'; return 0; }
  local f="$STATE_DIR/langs/$code.json" k v
  if [ ! -s "$f" ]; then
    mkdir -p "$STATE_DIR/langs"
    curl -fsSL -m 20 "$REPO_RAW/langs/$code.json" -o "$f.tmp" 2>/dev/null && [ "$(stat -c%s "$f.tmp")" -gt 1000 ] && mv "$f.tmp" "$f"
    rm -f "$f.tmp"
  fi
  [ -s "$f" ] || return 0
  while IFS=$'\t' read -r k v; do TRMAP["$k"]=$v; done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$f" 2>/dev/null)
}

# ---------------------------------------------------------------- theme and drawing
# v2.60.1: more themes are read from themes/themes.txt of the repository, cached in $STATE_DIR/themes (like the
# languages). The five built-in themes are in set_theme, so the launcher works offline. Line format:
# name|title|accent|border|selected|rainbow (codes are digits and ;; rainbow 1 or 0). Bad lines are skipped, max 30.
THEMES_VER=1
THEME_BUILTIN="ocean forest sunset mono rainbow"
THEME_SGR_RE='^[0-9;]{1,20}$'
declare -A THEME_EXTRA=()
load_themes(){
  local f="$STATE_DIR/themes/themes.txt" base=${OC_THEME_BASE:-$REPO_RAW/themes} n t a b s r cnt=0 names="" i
  if [ ! -s "$f" ] || [ "$(cat "$f.ver" 2>/dev/null)" != "$THEMES_VER" ]; then
    if [ ! -e "$f.failed" ] || [ -n "$(find "$f.failed" -mmin +60 2>/dev/null)" ]; then
      mkdir -p "$STATE_DIR/themes"
      case $base in
        http*) curl -fsSL -m 8 "$base/themes.txt" -o "$f.tmp" 2>/dev/null;;
        *)     cp "$base/themes.txt" "$f.tmp" 2>/dev/null;;
      esac
      if [ -s "$f.tmp" ] && grep -Eq '^[a-z][a-z0-9_-]{1,19}\|[0-9;]{1,20}\|[0-9;]{1,20}\|[0-9;]{1,20}\|[0-9;]{1,20}\|[01]\r?$' "$f.tmp"; then
        mv "$f.tmp" "$f"; echo "$THEMES_VER" > "$f.ver"; rm -f "$f.failed"; log 'themes downloaded'
      else
        rm -f "$f.tmp"; : > "$f.failed"; log 'themes not downloaded'
      fi
    fi
  fi
  THEME_EXTRA=()
  if [ -s "$f" ]; then
    while IFS='|' read -r n t a b s r; do
      r=${r%$'\r'}
      [[ $n =~ ^[a-z][a-z0-9_-]{1,19}$ ]] || continue
      case " $THEME_BUILTIN " in *" $n "*) continue;; esac
      [[ $t =~ $THEME_SGR_RE && $a =~ $THEME_SGR_RE && $b =~ $THEME_SGR_RE && $s =~ $THEME_SGR_RE && $r =~ ^[01]$ ]] || continue
      THEME_EXTRA[$n]="$t|$a|$b|$s|$r"; names+=" $n"; cnt=$((cnt + 1))
      [ "$cnt" -ge 30 ] && break
    done < "$f"
  fi
  names=$(printf '%s\n' $names | sort | paste -sd, -)
  for i in "${!SK[@]}"; do [ "${SK[i]}" = OCUI_THEME ] && SO[i]="ocean,forest,sunset,mono,rainbow${names:+,$names}"; done
}
set_theme(){
  local t a b s r
  OCUI_THEME=$1
  case $OCUI_THEME in
    forest)  TH=([title]='1;92' [acc]='32' [border]='32' [sel]='30;42' [panel]='' [warn]='33' [ok]='32' [err]='31' [dim]='90');;
    sunset)  TH=([title]='1;95' [acc]='35' [border]='35' [sel]='30;45' [panel]='' [warn]='33' [ok]='32' [err]='31' [dim]='90');;
    mono)    TH=([title]='1' [acc]='0' [border]='0' [sel]='7' [panel]='' [warn]='0' [ok]='0' [err]='0' [dim]='2');;
    rainbow) TH=([title]='rain' [acc]='rain' [border]='rain' [sel]='' [panel]='' [warn]='33' [ok]='32' [err]='31' [dim]='90');;
    *)
      if [ -n "${THEME_EXTRA[$OCUI_THEME]:-}" ]; then
        IFS='|' read -r t a b s r <<< "${THEME_EXTRA[$OCUI_THEME]}"
        TH=([title]=$t [acc]=$a [border]=$b [sel]=$s [panel]='' [warn]='33' [ok]='32' [err]='31' [dim]='90')
      else
        OCUI_THEME=ocean; TH=([title]='1;96' [acc]='36' [border]='34' [sel]='30;46' [panel]='' [warn]='33' [ok]='32' [err]='31' [dim]='90')
      fi;;
  esac
  RAIN=0; [ "$OCUI_THEME" = rainbow ] && RAIN=1
  if [ "${r:-0}" = 1 ]; then
    RAIN=1; TH=([title]='rain' [acc]='rain' [border]='rain' [sel]='' [panel]='' [warn]='33' [ok]='32' [err]='31' [dim]='90')
  fi
  COLOR=1; [ -n "${NO_COLOR:-}" ] && COLOR=0
  case $OCUI_COLOR in on) COLOR=1;; off) COLOR=0;; esac
  if [ "$OCUI_ICONS" = ascii ] || { [ "$OCUI_ICONS" = auto ] && [[ "${LC_ALL:-${LANG:-}}" != *UTF-8* && "${LC_ALL:-${LANG:-}}" != *utf8* ]]; }; then
    BOX_TL='+' BOX_TR='+' BOX_BL='+' BOX_BR='+' BOX_H='-' BOX_V='|'
  else
    BOX_TL='╭' BOX_TR='╮' BOX_BL='╰' BOX_BR='╯' BOX_H='─' BOX_V='│'
  fi
}
# hue 0-359 to RGB="r;g;b", one step of the rainbow
hue_rgb(){
  local h=$(( ($1 % 360 + 360) % 360 )) s f q
  s=$(( h / 60 )); f=$(( 255 * (h % 60) / 60 )); q=$(( 255 - f ))
  case $s in
    0) RGB="255;$f;0";; 1) RGB="$q;255;0";; 2) RGB="0;255;$f";;
    3) RGB="0;$q;255";; 4) RGB="$f;0;255";; *) RGB="255;0;$q";;
  esac
}
# code_of <name>: sets CODE to the SGR code of a theme slot (no subshell: this runs every frame)
code_of(){
  case $1 in
    sel) if [ "$RAIN" = 1 ]; then hue_rgb $(( RAIN_PH * 8 + 180 )); CODE="30;48;2;$RGB"; else CODE=${TH[sel]}; fi;;
    border) if [ "$RAIN" = 1 ]; then hue_rgb $(( RAIN_PH * 8 )); CODE="38;2;$RGB"; else CODE=${TH[border]}; fi;;
    *) CODE=${TH[$1]};;
  esac
}
# rep <char> <count>: sets REP to the char repeated
rep(){ printf -v REP '%*s' "$2" ''; REP=${REP// /$1}; }
FRAME=""; RAIN_PH=0
# pt <code> <text>: appends colored text to FRAME. code "rain" colors each letter on its own hue
pt(){
  if [ "$COLOR" != 1 ] || [ -z "$1" ]; then FRAME+="$2"; return; fi
  if [ "$1" != rain ]; then FRAME+="${ESC}[$1m$2${ESC}[0m"; return; fi
  local s=$2 i=0 k ch out=""
  for ((k = 0; k < ${#s}; k++)); do
    ch=${s:k:1}
    if [ "$ch" = " " ]; then out+=" "; continue; fi
    hue_rgb $(( RAIN_PH * 8 + i * 28 )); out+="${ESC}[38;2;${RGB}m$ch"; i=$(( i + 1 ))
  done
  FRAME+="$out${ESC}[0m"
}
eol(){ FRAME+="${ESC}[K"$'\n'; }
margin(){ FRAME+="$MARG"; }
banner(){
  local art=(
    ' ___   ____   _____  _   _   ____  ___   ____   _____   '
    '/ _ \ |  _ \ | ____|| \ | | / ___|/ _ \ |  _ \ | ____|  '
    '| | | || |_) ||  _|  |  \| || |    | | | || | | ||  _|  '
    '| |_| ||  __/ | |___ | |\  || |___ | |_| || |_| || |___ '
    ' \___/ |_|    |_____||_| \_| \____| \___/ |____/ |_____|'
    ' ___  _   _  _____  ___  _   _  ___  _____  _____       '
    '|_ _|| \ | ||  ___||_ _|| \ | ||_ _||_   _|| ____|      '
    ' | | |  \| || |_    | | |  \| | | |   | |  |  _|        '
    ' | | | |\  ||  _|   | | | |\  | | |   | |  | |___       '
    '|___||_| \_||_|    |___||_| \_||___|  |_|  |_____|      ')
  local r c
  for r in "${!art[@]}"; do
    margin
    if [ "$RAIN" = 1 ]; then c=rain; elif [ "$r" -lt 5 ]; then c=${TH[title]}; else c=${TH[acc]}; fi
    pt "$c" "${art[r]}"; eol
  done
  margin; pt "${TH[acc]}" "$REPO"; eol; margin; eol
}
# boxline <code> <text>: | text |, the text is padded to the inner width
boxline(){
  local inner=$(( W - 4 )) text=$2; text=${text:0:inner}
  code_of border; local bc=$CODE
  margin; pt "$bc" "$BOX_V "; pt "$1" "$(printf '%-*s' "$inner" "$text")"; pt "$bc" " $BOX_V"; eol
}
boxtop(){
  local t=" $1 " fill
  fill=$(( W - 3 - ${#t} )); rep "$BOX_H" "$fill"
  code_of border; local bc=$CODE; code_of title; local tc=$CODE
  margin; pt "$bc" "$BOX_TL$BOX_H"; pt "$tc" "$t"; pt "$bc" "$REP$BOX_TR"; eol
}
boxbot(){ rep "$BOX_H" $(( W - 2 )); code_of border; margin; pt "$CODE" "$BOX_BL$REP$BOX_BR"; eol; }

# menu state: ML labels, MV values, MH help, MD disabled flags, MVS value colour slots; HEAD lines as "code|text"
reset_items(){ ML=(); MV=(); MH=(); MD=(); MVS=(); HEAD=(); }
item(){ ML+=("$1"); MV+=("${2:-}"); MH+=("${3:-}"); MD+=("${4:-}"); MVS+=("${5:-acc}"); }
draw(){
  local title=$1 foot=$2 n=${#ML[@]} i lab val gap room help
  FRAME=""
  COLUMNS=${COLUMNS:-80}
  W=$(( COLUMNS - 2 )); (( W > 74 )) && W=74; (( W < 56 )) && W=56
  local M=$(( (COLUMNS - W) / 2 )); (( M < 0 )) && M=0
  printf -v MARG '%*s' "$M" ''
  [ "$SHOW_BANNER" = 1 ] && banner
  local h
  for h in "${HEAD[@]}"; do margin; pt "${h%%|*}" "${h#*|}"; eol; done
  [ ${#HEAD[@]} -gt 0 ] && { margin; eol; }
  boxtop "$title"
  for ((i = 0; i < n; i++)); do
    lab="${ML[i]}"; val="${MV[i]}"
    room=$(( W - 10 - ${#lab} )); (( room < 4 )) && room=4
    [ ${#val} -gt "$room" ] && val="${val:0:$(( room - 2 ))}.."
    gap=$(( W - 9 - ${#lab} - ${#val} )); (( gap < 1 )) && gap=1
    printf -v gap '%*s' "$gap" ''
    if [ "$i" -eq "$SEL" ]; then
      code_of sel; local sc=$CODE
      code_of border; local bc=$CODE
      margin; pt "$bc" "$BOX_V "; pt "$sc" "> $(( i + 1 )). $lab$gap$val"; pt "$bc" " $BOX_V"; eol
    else
      code_of border; local bc=$CODE
      local dc=""; [ -n "${MD[i]}" ] && dc=${TH[dim]}
      code_of "${MVS[i]}"; local vc=$CODE
      margin; pt "$bc" "$BOX_V   "; pt "$dc" "$(( i + 1 )). $lab"; pt "" "$gap"; pt "$vc" "$val"; pt "$bc" " $BOX_V"; eol
    fi
  done
  boxbot
  help="${MH[SEL]}"
  if [ -n "${MV[SEL]}" ] && [ ${#MV[SEL]} -gt $(( W - 4 )) ]; then help="Value: ${MV[SEL]}  $help"; fi
  local lines=() ww=$(( W - 4 )) cur="" word q
  for word in $help; do
    if [ -z "$cur" ]; then cur=$word; elif [ $(( ${#cur} + 1 + ${#word} )) -le "$ww" ]; then cur+=" $word"; else lines+=("$cur"); cur=$word; fi
  done
  [ -n "$cur" ] && lines+=("$cur")
  for ((q = 0; q < 3; q++)); do
    margin
    if [ "$q" -lt ${#lines[@]} ]; then
      if [ "$q" -eq 0 ]; then pt "${TH[acc]}" "i ${lines[q]}"; else pt "${TH[acc]}" "  ${lines[q]}"; fi
    fi
    eol
  done
  margin; pt "${TH[dim]}" "arrows move   Enter select   Esc back   1-9 jump"; eol
  if [ -n "$foot" ]; then margin; pt "${TH[dim]}" "$foot"; eol; fi
  printf '\e[H%s\e[J' "$FRAME"
}
# getkey <seconds>: sets KEY. Returns 1 on timeout (KEY=__timeout).
getkey(){
  KEY=""
  if ! IFS= read -rsn1 -t "$1" KEY; then KEY=__timeout; return 1; fi
  if [ "$KEY" = "$ESC" ]; then
    local r=""; IFS= read -rsn2 -t 0.03 r
    case $r in '[A'|'OA') KEY=Up;; '[B'|'OB') KEY=Down;; '[H'|'OH') KEY=Home;; '[F'|'OF') KEY=End;; '') KEY=Esc;; *) KEY=Other;; esac
  elif [ -z "$KEY" ]; then KEY=Enter
  elif [ "$KEY" = $'\x7f' ]; then KEY=Esc
  fi
  return 0
}
# menu <title> [footer]: draws the items and returns the chosen index in MRES (-1 on Esc)
menu(){
  local title=$1 foot=${2:-} n=${#ML[@]} idx
  while :; do
    draw "$title" "$foot"
    if [ "$RAIN" = 1 ]; then
      if ! getkey 0.09; then RAIN_PH=$(( RAIN_PH + 1 )); continue; fi
    else
      getkey 3600 || continue
    fi
    case $KEY in
      Up) SEL=$(( (SEL - 1 + n) % n ));;
      Down) SEL=$(( (SEL + 1) % n ));;
      Home) SEL=0;;
      End) SEL=$(( n - 1 ));;
      Enter) if [ -z "${MD[SEL]}" ]; then MRES=$SEL; return 0; fi;;
      Esc) MRES=-1; return 0;;
      [1-9]) idx=$(( KEY - 1 )); if [ "$idx" -lt "$n" ] && [ -z "${MD[idx]}" ]; then MRES=$idx; return 0; fi;;
    esac
  done
}
# ask <prompt> <default>: reads one line, empty keeps the default. Sets ANSWER.
ask(){
  printf '\e[H\e[J%s\n%s%s%s [%s]: ' "" "$MARG" "${ESC}[${TH[acc]}m" "$1" "$2${ESC}[0m"
  stty echo icanon 2>/dev/null
  IFS= read -r ANSWER || { stty -echo -icanon 2>/dev/null; return 1; }
  stty -echo -icanon 2>/dev/null
  [ -z "$ANSWER" ] && ANSWER=$2
  return 0
}
say(){ local kind=$1; shift; [ "${OPT_QUIET:-0}" = 1 ] && [ "$kind" != err ] && return 0; printf '\n%s%s%s%s\n' "$MARG" "${ESC}[${TH[$kind]}m" "$*" "${ESC}[0m"; }  # --quiet: only errors show
pause(){ printf '\n%sPress any key to continue...' "$MARG"; IFS= read -rsn1 _; }
# confirm <question>: 0 when the user picks Yes
confirm(){
  reset_items; HEAD=("${TH[warn]}|$1" ""); SHOW_BANNER=0
  item "$(tx 'No, cancel')" '' 'Go back. Nothing is changed.'
  item "$(tx 'Yes, continue')" '' 'Do it now.' '' warn
  SEL=0; menu 'Confirm'
  [ "$MRES" = 1 ]
}
# with_tty <cmd...>: runs a command that may ask for a password, with a normal terminal
with_tty(){ stty sane 2>/dev/null; "$@"; local rc=$?; stty -echo -icanon 2>/dev/null; return $rc; }
desk_dir(){ local d; d=$(xdg-user-dir DESKTOP 2>/dev/null) || true; [ -n "$d" ] || d="$HOME/Desktop"; mkdir -p "$d"; printf '%s' "$d"; }

# ---------------------------------------------------------------- settings helpers
show_val(){
  local k=${SK[$1]} v; v=${!k}
  case ${ST[$1]} in
    bool) [ "$v" = 1 ] && echo on || echo off;;
    *) [ -n "$v" ] && echo "$v" || echo "(empty)";;
  esac
}
# valid_val <index> <value>: 0 when the value fits that setting
valid_val(){
  local i=$1 v=$2 o lo hi x
  case ${ST[i]} in
    bool) [[ $v == 0 || $v == 1 ]];;
    num) IFS=: read -r lo hi <<< "${SO[i]}"; [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ];;
    enum) IFS=, read -ra o <<< "${SO[i]}"; for x in "${o[@]}"; do [ "$x" = "$v" ] && return 0; done; return 1;;
    key) [[ $v =~ ^[A-Za-z]$ ]];;
    *) [ "${SK[i]}" != TARGET_COUNTRY ] || [ -z "$v" ] || [[ $v =~ ^[A-Za-z]{2}$ ]];;
  esac
}
edit_setting(){ # bool toggles, enum cycles, num and text are asked
  local i=$1 k=${SK[$1]} v o j n nx=0
  v=${!k}
  case ${ST[i]} in
    bool) cfg_set "$k" $(( 1 - v ));;
    enum) IFS=, read -ra o <<< "${SO[i]}"; n=${#o[@]}
          for ((j = 0; j < n; j++)); do [ "${o[j]}" = "$v" ] && nx=$(( (j + 1) % n )); done
          cfg_set "$k" "${o[nx]}";;
    *) ask "$(tx "${SL[i]}")" "$v" || return 0
       [ "$ANSWER" = - ] && ANSWER=""
       [ "$k" = TARGET_COUNTRY ] && ANSWER=${ANSWER^^}
       if valid_val "$i" "$ANSWER"; then cfg_set "$k" "$ANSWER"; else say err "not allowed: ${SO[i]:-$( [ "${ST[i]}" = key ] && echo one letter || echo two letters or empty )}"; pause; fi;;
  esac
}
group_menu(){ # the settings of one group; Enter edits the chosen one
  local g=$1 i n idx
  while :; do
    reset_items; HEAD=(); SHOW_BANNER=0; idx=()
    for i in "${!SK[@]}"; do
      [ "${SG[i]}" = "$g" ] || continue
      idx+=("$i"); item "$(tx "${SL[i]}")" "$(show_val "$i")" "$(tx "${SH[i]}")"
    done
    n=${#idx[@]}; item "$(tx 'Back')" '' 'Return to the settings.'
    menu "$(tx "$g")"
    [ "$MRES" -ge 0 ] && [ "$MRES" -lt "$n" ] || return 0
    edit_setting "${idx[MRES]}"
    load_cfg; set_theme "$OCUI_THEME"; load_lang
  done
}
export_settings(){
  local f; f="$(desk_dir)/opencode-infinite-settings.env"
  grep -v -i 'token\|password' "$CONF" > "$f" 2>/dev/null || : > "$f"
  say ok "settings saved to $f"; pause
}
import_settings(){ # only known keys with valid values are taken
  local k v i n=0 bad=0
  ask 'Settings file to import' "$(desk_dir)/opencode-infinite-settings.env" || return 0
  [ -f "$ANSWER" ] || { say err "not a file: $ANSWER"; pause; return 0; }
  while IFS='=' read -r k v; do
    for i in "${!SK[@]}"; do
      [ "${SK[i]}" = "$k" ] || continue
      if valid_val "$i" "$v"; then cfg_set "$k" "$v"; n=$(( n + 1 )); else bad=$(( bad + 1 )); fi
    done
  done < "$ANSWER"
  say ok "imported $n setting(s), skipped $bad invalid line(s)."; pause
}
reset_settings(){
  confirm 'Set every setting back to its default? Chats are not touched.' || return 0
  local pat; pat=$(IFS='|'; printf '%s' "${SK[*]}")
  touch "$CONF"; grep -v -E "^($pat)=" "$CONF" > "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
  say ok 'settings are back to their defaults.'; pause
}
support_menu(){
  local -a acts=(export_settings import_settings reset_settings make_shortcut check_updates support_report)
  while :; do
    reset_items; HEAD=(); SHOW_BANNER=0
    item "$(tx 'Export settings')" '' 'Save the settings to a file on the Desktop.'
    item "$(tx 'Import settings')" '' 'Load a settings file. Unknown or invalid lines are skipped.'
    item "$(tx 'Reset settings')" '' 'Set every setting back to its default. Chats are not touched.'
    item "$(tx 'Desktop shortcut')" '' 'Create the OpenCode Infinite launcher icon.'
    item "$(tx 'Check for updates')" '' 'Look for a newer launcher and a newer opencode now.'
    item "$(tx 'Support report')" '' 'Write one text file with versions, settings and the log, for help.'
    item "$(tx 'Back')" '' 'Return to the settings.'
    menu "$(tx 'Support')"
    [ "$MRES" -ge 0 ] && [ "$MRES" -lt 6 ] || return 0
    "${acts[MRES]}"; load_cfg; set_theme "$OCUI_THEME"; load_lang
  done
}
settings(){
  local groups=(Connection Tor 'Proxy list' Rotation Watcher Probe Updates Appearance Shortcuts Logs)
  local help=('Egress, WARP ports and timeouts.' 'Tor ports, bootstrap and install.' 'Free proxy list source and tests.' 'Rotation, IP target and the hunt.' 'Watching OpenCode and resuming.' 'The IP probe.' 'Update prompts.' 'Theme, colors, icons and language.' 'Keys for the closed-OpenCode prompt.' 'Activity log and report privacy.')
  local g i
  while :; do
    reset_items; HEAD=(); SHOW_BANNER=0
    for i in "${!groups[@]}"; do item "$(tx "${groups[i]}")" '' "${help[i]}"; done
    item "$(tx 'Support')" '' 'Export, import, reset settings, shortcut, updates and the support report.'
    item "$(tx 'Back')" '' 'Return to the home screen.'
    menu "$(tx 'Settings')"
    if [ "$MRES" -ge 0 ] && [ "$MRES" -lt "${#groups[@]}" ]; then group_menu "${groups[MRES]}"
    elif [ "$MRES" -eq "${#groups[@]}" ]; then support_menu
    else return 0; fi
  done
}

# ---------------------------------------------------------------- egress: WARP
warp_wc(){ timeout "$WARP_CALL_TIMEOUT" warp-cli --accept-tos "$@" >>"$STATE_DIR/wcli.log" 2>&1; }
warp_check(){ # prints the exit IP when the WARP proxy answers with warp=on
  local out; out=$(curl -s -m 15 -x "http://127.0.0.1:$PROXY_PORT" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  printf '%s' "$out" | grep -qE '^warp=(on|plus)' || return 1
  printf '%s' "$out" | sed -n 's/^ip=//p'
}
# warp_svc_ensure: starts the WARP service when it is down. Never asks for a password: sudo -n only (works without a password or with cached rights).
warp_svc_ensure(){
  command -v systemctl >/dev/null || return 0
  systemctl is-active --quiet warp-svc && return 0
  if [ "$(id -u)" -eq 0 ]; then systemctl enable --now warp-svc >>"$LOG" 2>&1
  elif [ "${OPT_AUTO:-0}" = 1 ]; then sudo -n systemctl enable --now warp-svc >>"$LOG" 2>&1
  else sudo -n systemctl enable --now warp-svc >>"$INSTALL_LOG" 2>&1; fi
  sleep 2; systemctl is-active --quiet warp-svc
}
warp_up(){
  command -v warp-cli >/dev/null || { log 'warp-cli missing'; return 1; }
  warp_svc_ensure || { log 'warp-svc is not running and could not be started (sudo)'; return 1; }
  warp_wc registration show >/dev/null 2>&1 || warp_wc registration new
  warp_wc mode proxy; warp_wc proxy port "$PROXY_PORT"; warp_wc connect
  local i; for i in $(seq 1 "$WARP_WAIT"); do warp-cli --accept-tos status 2>/dev/null | grep -q 'Connected' && break; sleep 1; done
  warp_check >/dev/null
}
warp_rotate(){
  command -v warp-cli >/dev/null || return 1
  warp_wc registration delete; warp_wc registration new || return 1
  warp_up
}

# ---------------------------------------------------------------- egress: TOR (user tor + privoxy bridge)
port_open(){ (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; } # bash builtin, no ss or iproute2 needed
tor_running(){ port_open "$TOR_SOCKS_PORT"; }
# v0.3.3: polls once a second, at most $3 s, until port $1 is up or down ($2), instead of a fixed sleep
port_wait(){ local i; for ((i = 0; i < $3; i++)); do if port_open "$1"; then [ "$2" = up ] && return 0; else [ "$2" = down ] && return 0; fi; sleep 1; done; return 1; }
tor_start(){
  command -v tor >/dev/null || { log 'tor missing'; return 1; }
  command -v privoxy >/dev/null || { log 'privoxy missing'; return 1; }
  if ! tor_running; then
    : > "$STATE_DIR/tor.log"  # a log left by an earlier run would end the wait below at once
    tor --SocksPort "$TOR_SOCKS_PORT" --DataDirectory "$STATE_DIR/tor" --Log "notice file $STATE_DIR/tor.log" >/dev/null 2>&1 &
    echo $! > "$STATE_DIR/tor.pid"
    local i; for i in $(seq 1 "$TOR_BOOTSTRAP_WAIT"); do grep -q 'Bootstrapped 100%' "$STATE_DIR/tor.log" 2>/dev/null && break; sleep 1; done
  fi
  printf 'listen-address 127.0.0.1:%s\nforward-socks5t / 127.0.0.1:%s .\n' "$TOR_HTTP_PORT" "$TOR_SOCKS_PORT" > "$STATE_DIR/privoxy.conf"
  if ! port_open "$TOR_HTTP_PORT"; then
    privoxy --no-daemon "$STATE_DIR/privoxy.conf" >/dev/null 2>&1 &
    echo $! > "$STATE_DIR/privoxy.pid"; port_wait "$TOR_HTTP_PORT" up 10  # v0.3.3: poll, no fixed sleep
  fi
  # a port that is open is not enough: the bridge on it must route through Tor
  if curl -s -m 30 -x "http://127.0.0.1:$TOR_HTTP_PORT" https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true'; then return 0; fi
  log "tor bridge on $TOR_HTTP_PORT does not route through tor (port busy or tor not ready)"
  return 1
}
tor_stop(){
  local tp; tp=$(cat "$STATE_DIR/tor.pid" 2>/dev/null)
  # v2.60: kill only while that PID is still our tor (a reused PID must not be killed)
  if [ -n "$tp" ] && tr '\0' ' ' < "/proc/$tp/cmdline" 2>/dev/null | grep -q "DataDirectory $STATE_DIR/tor"; then kill "$tp" 2>/dev/null; fi
  pkill -f "DataDirectory $STATE_DIR/tor" 2>/dev/null
  rm -f "$STATE_DIR/tor.pid"
}
tor_check(){ # prints the Tor exit IP when check.torproject.org says IsTor
  local out; out=$(curl -s -m 30 --socks5-hostname "127.0.0.1:$TOR_SOCKS_PORT" https://check.torproject.org/api/ip 2>/dev/null)
  printf '%s' "$out" | grep -q '"IsTor":true' || return 1
  printf '%s' "$out" | sed -n 's/.*"IP":"\([^"]*\)".*/\1/p'
}
tor_rotate(){ tor_stop; port_wait "$TOR_SOCKS_PORT" down 5; tor_start && tor_check >/dev/null; }  # v0.3.3: wait for the old tor to leave, no fixed sleep

# ---------------------------------------------------------------- egress: PROXY list
proxy_pick(){ # the list is a URL or a local file, any format: every ip:port in it is a candidate
  local raw list p code tries=0
  if [ -f "$PROXY_LIST_URL" ]; then raw=$(cat "$PROXY_LIST_URL"); else raw=$(curl -s -m 20 "$PROXY_LIST_URL"); fi
  if [ "$PROXY_LIST_MIN_BYTES" -gt 0 ] && [ "$(printf '%s' "$raw" | wc -c)" -lt "$PROXY_LIST_MIN_BYTES" ]; then log 'proxy list smaller than PROXY_LIST_MIN_BYTES'; return 1; fi
  list=$(printf '%s' "$raw" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]{2,5}' | sort -u | shuf | head -n 200)
  [ -n "$list" ] || { log 'proxy list empty'; return 1; }
  while IFS= read -r p; do
    tries=$(( tries + 1 )); [ "$tries" -gt "$PROXY_TRY_MAX" ] && break
    curl -s -m "$PROXY_PROBE_TIMEOUT" -x "http://$p" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^ip=' || continue
    if [ "$PROXY_API_CHECK" = 1 ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' -m "$PROXY_PROBE_TIMEOUT" -x "http://$p" "$PROXY_API_CHECK_URL")
      [ "$code" = 000 ] && continue
    fi
    PROXY_URL="http://$p"; return 0
  done <<< "$list"
  return 1
}

# ---------------------------------------------------------------- egress control
# method_installed <WARP|TOR|PROXY>: PROXY needs no install (its list is downloaded at each use)
method_installed(){
  case $1 in
    WARP) command -v warp-cli >/dev/null;;
    TOR) command -v tor >/dev/null && command -v privoxy >/dev/null;;
    PROXY) command -v curl >/dev/null;;
    *) return 1;;
  esac
}
# method_ms <method>: the last measured route time in ms (empty = never measured on this machine)
method_ms(){ cat "$STATE_DIR/method_$1.ms" 2>/dev/null; }
# auto_pick: the installed method with the lowest measured time; none measured = PROXY (same rule as the .bat)
auto_pick(){
  local m ms best="" bestms=""
  for m in WARP TOR PROXY; do
    method_installed "$m" || continue
    ms=$(method_ms "$m"); [[ $ms =~ ^[0-9]+$ ]] || continue
    if [ -z "$bestms" ] || [ "$ms" -lt "$bestms" ]; then best=$m; bestms=$ms; fi
  done
  printf '%s' "${best:-PROXY}"
}
# auto_chain <first>: the picked method, then the other installed ones in WARP, TOR, PROXY order
auto_chain(){
  local m; printf '%s\n' "$1"
  for m in WARP TOR PROXY; do [ "$m" = "$1" ] && continue; method_installed "$m" && printf '%s\n' "$m"; done
  return 0
}
egress_up(){
  local t0; PROXY_URL=""; t0=$(date +%s%3N)
  case $EGRESS in
    WARP) warp_up && PROXY_URL="http://127.0.0.1:$PROXY_PORT";;
    TOR) tor_start && PROXY_URL="http://127.0.0.1:$TOR_HTTP_PORT";;
    PROXY) proxy_pick;;
    *) return 0;;
  esac
  [ -n "$PROXY_URL" ] || return 1
  printf '%s' $(( $(date +%s%3N) - t0 )) > "$STATE_DIR/method_$EGRESS.ms"  # the route time Auto ranks the methods by
  return 0
}
egress_rotate(){ # one new route for the current egress; 0 when it is up
  case $EGRESS in
    WARP) warp_rotate && PROXY_URL="http://127.0.0.1:$PROXY_PORT";;
    TOR) tor_rotate && PROXY_URL="http://127.0.0.1:$TOR_HTTP_PORT";;
    PROXY) proxy_pick;;
    *) return 1;;
  esac
}
trace_get(){ # the Cloudflare trace of the current route, empty when it does not answer
  local args=(); [ -n "${PROXY_URL:-}" ] && args=(-x "$PROXY_URL")
  curl -s -m 15 "${args[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null
}
current_ip(){ trace_get | sed -n 's/^ip=//p'; }
route_ok(){ # $1 = trace text. WARP must report warp=on, the others only need an answer
  if [ "$EGRESS" = WARP ]; then printf '%s' "$1" | grep -Eq '^warp=(on|plus)' || return 1; fi
  return 0
}
target_match(){ # target_match <ip> <country>: 0 when every target that is set matches
  [ -z "$TARGET_COUNTRY" ] || [ "${2^^}" = "${TARGET_COUNTRY^^}" ] || return 1
  [ -z "$TARGET_PREFIX" ] || [[ "$1" == "$TARGET_PREFIX"* ]] || return 1
}
probe_ip(){ # 0 = usable, 1 = burned (a limit answer), 2 = the probe itself is broken
  [ "$PROBE" = 1 ] || return 0
  local out rc sid
  oc_runner; export_proxy
  # --standalone: the shared server ignores the proxy env, so without it the probe would test the wrong route
  local pm=(); [ -n "$PROBE_MODEL" ] && pm=(--model "$PROBE_MODEL")
  "${RUNNER[@]}" run --help 2>&1 | grep -q -- --standalone && pm+=(--standalone)  # only builds that have the flag
  out=$(cd "$HOME" && timeout -k 5 120 "${RUNNER[@]}" run --format json "${pm[@]}" "reply with the word ok" 2>&1); rc=$?
  sid=$(printf '%s' "$out" | grep -o 'ses_[A-Za-z0-9]*' | head -n1)
  [ -n "$sid" ] && "${RUNNER[@]}" session delete "$sid" >/dev/null 2>&1
  if printf '%s' "$out" | grep -Eiq "$OC_PAT|usage limit|rate limit|out of usage|insufficient credits|payment required|free usage"; then return 1; fi
  [ "$rc" = 0 ] && return 0
  return 2
}
# v0.3.3: ip_key <ip>: IPv4 as is; IPv6 as its first 4 groups (/64), "::" expanded, zero padded
ip_key(){
  local ip=${1,,} a b n i out=""
  [[ $ip == *:* ]] || { printf '%s' "$ip"; return 0; }
  ip=${ip%%%*}
  if [[ $ip == *::* ]]; then
    IFS=: read -ra a <<< "${ip%%::*}"; IFS=: read -ra b <<< "${ip#*::}"
    for ((n = 8 - ${#a[@]} - ${#b[@]}; n > 0; n--)); do a+=(0); done; a+=("${b[@]}")
  else IFS=: read -ra a <<< "$ip"; fi
  for i in 0 1 2 3; do out+=$(printf '%04x' "0x${a[i]:-0}" 2>/dev/null); done
  printf '%s' "$out"
}
same_ip(){ [ -n "$1" ] && [ -n "$2" ] && [ "$(ip_key "$1")" = "$(ip_key "$2")" ]; }
# rot_log <reason>: one line per rotation attempt (reads prev, ip, i, tries, start of hunt_new)
rot_log(){ log "rotate prev=${prev:-none} new=${ip:-none} try=$i/$tries t=$(( $(date +%s) - start ))s reason=$1"; }
# hunt_new: rotates until a route passes the target and the probe. 0 = accepted, 1 = gave up
hunt_new(){
  local tries interval goal=0 i t ip gl burned=0 broken=0 start p prev="" seen="" same=0 end r0
  [ "$EGRESS" = NONE ] && { say warn 'Egress is NONE - nothing to rotate.'; return 1; }
  if [ -n "$TARGET_COUNTRY$TARGET_PREFIX" ]; then goal=1; tries=$TARGET_TRIES; interval=$TARGET_INTERVAL; else tries=$ROTATE_TRIES_MAX; interval=$ROTATE_COOLDOWN; fi
  start=$(date +%s)
  [ -n "${PROXY_URL:-}" ] && prev=$(current_ip); seen=$prev  # v0.3.3: the IP to get away from
  for ((i = 1; i <= tries; i++)); do
    if [ "$goal" = 1 ] && [ $(( $(date +%s) - start )) -gt $(( TARGET_MINUTES * 60 )) ]; then say warn 'target hunt: time is up.'; return 1; fi
    [ "${OPT_QUIET:-0}" = 1 ] || printf '\n%s  [%d/%d] rotating...\n' "$MARG" "$i" "$tries"
    r0=$(date +%s%3N)
    if ! egress_rotate; then say warn '  rotation failed'; ip=""; rot_log rotate_failed; sleep "$interval"; continue; fi
    # v0.3.3: poll the new route every second for up to WARP_WAIT s
    end=$(( SECONDS + WARP_WAIT ))
    while :; do
      t=$(trace_get)
      ip=$(printf '%s' "$t" | sed -n 's/^ip=//p'); gl=$(printf '%s' "$t" | sed -n 's/^loc=//p')
      { [ -n "$ip" ] && route_ok "$t"; } && break
      [ "$SECONDS" -ge "$end" ] && break
      sleep 1
    done
    if [ -z "$ip" ] || ! route_ok "$t"; then say warn '  route not answering'; rot_log route_down; sleep "$interval"; continue; fi
    printf '%s' $(( $(date +%s%3N) - r0 )) > "$STATE_DIR/method_$EGRESS.ms"  # route time for Auto's pick
    say ok "  exit IP $ip (country $gl)"
    # v0.3.3: the same IP (same /64 on IPv6) is no rotation: retry after ROTATE_COOLDOWN, give up after ROTATE_TRIES_MAX in a row
    if same_ip "$ip" "$seen"; then
      same=$(( same + 1 )); say warn "  same IP as before ($same of $ROTATE_TRIES_MAX), trying again"; rot_log same_ip
      if [ "$same" -ge "$ROTATE_TRIES_MAX" ]; then say err 'the rotation keeps returning the same IP.'; return 1; fi
      sleep "$ROTATE_COOLDOWN"; continue
    fi
    same=0; seen=$ip
    if ! target_match "$ip" "$gl"; then rot_log "target_mismatch country=$gl"; sleep "$interval"; continue; fi
    probe_ip; p=$?
    case $p in
      0) rot_log "accepted country=$gl"; return 0;;
      1) burned=$(( burned + 1 )); rot_log burned; say warn '  IP already burned, rotating again...'
         if [ "$IP_FIND_MAX" -gt 0 ] && [ "$burned" -ge "$IP_FIND_MAX" ]; then say err 'burned IP limit reached.'; return 1; fi
         if [ "$EGRESS" = PROXY ] && [ "$burned" -ge "$PROXY_ROT_MAX" ]; then
           burned=0
           if [ "$OPT_AUTO" != 1 ] && confirm 'Too many burned proxies. Switch this hunt to Tor?'; then EGRESS=TOR; say ok 'switched to Tor for this run.'; fi  # Auto never asks: it stays on PROXY
         fi;;
      *) broken=$(( broken + 1 )); rot_log probe_failed; say err "  probe failed for a reason that is not a limit ($broken of $PROBE_BROKEN_MAX)"
         if [ "$broken" -ge "$PROBE_BROKEN_MAX" ]; then say err 'the probe looks broken. Check Probe model in Settings > Probe.'; return 1; fi;;
    esac
    sleep "$interval"
  done
  ip=""; i=$tries; rot_log "gave_up_after_$tries"
  return 1
}
egress_new(){ hunt_new; }
export_proxy(){ # the one place that sets the proxy env: new chat, resume, probe and crash retry all call it
  # v0.3.3: loopback never goes through the proxy (ECONNRESET on 127.0.0.1 after a rotation); ALL_PROXY set like the others
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
  if [ -n "${PROXY_URL:-}" ]; then export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL" http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
  else unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; fi
}
# v0.3.3: log_resume <command text> [opencode args]: what a resume uses, no secrets (proxy credentials masked, only flag names of the args)
log_resume(){
  local cmd=$1 a sid=last-chat prev="" flags=""; shift
  for a in "$@"; do
    case $prev in --session|-s) sid=$a;; esac
    case $a in --session=*) sid=${a#*=};; -*) flags+=" ${a%%=*}";; esac
    prev=$a
  done
  local px ip auth=no
  px=$(printf 'HTTP=%s HTTPS=%s ALL=%s NO=%s' "${HTTP_PROXY:-none}" "${HTTPS_PROXY:-none}" "${ALL_PROXY:-none}" "${NO_PROXY:-none}" | sed -E 's|//[^/@ ]*@|//***@|g')
  ip=$(current_ip); [ -s "$DATA_DIR/auth.json" ] && auth=yes
  log "resume: session=$sid exit_ip=${ip:-none} proxy=[$px] auth=$auth cmd=$cmd$flags"
}

# ---------------------------------------------------------------- tokens and crash streak
AUTH_SNAP_DIR="$STATE_DIR/auth_snapshot"
token_guard(){ # the logins survive restarts: a copy of auth.json is kept; if it vanished it is put back
  local auth="$DATA_DIR/auth.json" snap="$AUTH_SNAP_DIR/auth.json"
  if [ -e "$auth" ]; then
    [ "$(stat -c%s "$auth")" -ge 3 ] || return 0
    mkdir -p "$AUTH_SNAP_DIR" && cp -f "$auth" "$snap" 2>/dev/null
  elif [ -s "$snap" ]; then
    mkdir -p "$DATA_DIR" && cp -f "$snap" "$auth" || return 0
    log "tokens: auth.json was missing, restored from the launcher snapshot"
    say warn "auth.json had disappeared; it was restored from the launcher copy. No login needed."
  fi
}
drop_snapshot(){ rm -f "$AUTH_SNAP_DIR/auth.json"; } # a reset asked for by the user must not be undone
CRASH_STREAK=0; CRASH_LAST=0
crash_retry(){ # $1 = exit code. 0 = retry on the same egress, 1 = more than 2 crashes in 10 minutes, 2 = NONE: no retry
  local now wait; now=$(date +%s)
  [ $(( now - CRASH_LAST )) -gt 600 ] && CRASH_STREAK=0
  CRASH_LAST=$now; CRASH_STREAK=$(( CRASH_STREAK + 1 ))
  log "opencode crashed: code $1 streak $CRASH_STREAK egress=$EGRESS"
  if [ "$CRASH_STREAK" -gt 2 ]; then
    say err "OpenCode crashed $CRASH_STREAK times in 10 minutes. Stopped so it is not restarted in a loop. Details in launcher.log."
    return 1
  fi
  [ "$EGRESS" = NONE ] && return 2
  wait=$(( CRASH_STREAK * 2 ))
  say warn "OpenCode stopped with code $1. Retry $CRASH_STREAK of 2 on the same connection in ${wait} s; the chat resumes."
  sleep "$wait"
  return 0
}

# ---------------------------------------------------------------- run OpenCode, watch its log
oc_runner(){ # the command line that runs the real OpenCode (node for the npm build)
  case $OC_REAL in *.js|*.mjs|*.cjs) RUNNER=(node "$OC_REAL");; *) RUNNER=("$OC_REAL");; esac
}
# v0.3.3: only the PIDs this launcher started (OC_PIDS, written by run_session) are stopped, never every opencode of the machine.
# The cmdline check keeps a reused PID safe. A desktop app line is "pid starttime" (app_run).
stop_opencode(){
  local p st now sig rows
  [ -s "$OC_PIDS" ] || return 0
  mapfile -t rows < "$OC_PIDS"  # read once: run_session empties the file as soon as the app exits, the KILL pass still needs it
  for sig in TERM KILL; do
    while read -r p st; do
      [[ $p =~ ^[0-9]+$ ]] || continue
      if [ -n "$st" ]; then
        # desktop app, leader of its own group (setsid). Alive with another start time = reused PID, left alone.
        # Leader gone: a group number is not reused while members live, so -p reaches only what is left of ours
        now=$(pid_start "$p"); { [ -z "$now" ] || [ "$now" = "$st" ]; } && kill -"$sig" -- "-$p" 2>/dev/null
      else
        grep -qaF "$OC_REAL" "/proc/$p/cmdline" 2>/dev/null && kill -"$sig" "$p" 2>/dev/null
      fi
    done < <(printf '%s\n' "${rows[@]}")
    [ "$sig" = TERM ] && sleep 1
  done
  : > "$OC_PIDS"; return 0
}
pid_start(){ local s f; read -r s 2>/dev/null < "/proc/$1/stat" || return 1; read -ra f <<< "${s##*) }"; printf '%s' "${f[19]}"; } # field 22, after "pid (comm) "
# ---------------------------------------------------------------- desktop mode
app_find(){ # the desktop app: Desktop app path (OC_APP), the .deb install, then the PATH
  local p
  for p in "$OC_APP" /opt/OpenCode/ai.opencode.desktop "$(command -v ai.opencode.desktop)"; do
    [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
# app_run <folder> <app>: starts the app detached with the proxy env (export_proxy, called by run_session), records it in OC_PIDS, waits for it
app_run(){
  local pid out="$STATE_DIR/desktop.log"
  pgrep -f -- "$2" >/dev/null 2>&1 && say warn "$(tx 'An OpenCode opened outside the launcher is running. Close it so OpenCode uses the new route.')"
  mv -f "$out" "$out.1" 2>/dev/null
  # setsid does not fork here (a job of a non-interactive bash is no group leader), so $! is the app and its group id
  ( cd "$1" && exec setsid "$2" ) </dev/null >"$out" 2>&1 & pid=$!
  printf '%s %s\n' "$pid" "$(pid_start "$pid")" > "$OC_PIDS"
  log "desktop: started pid $pid: $2 proxy=$(printf '%s' "${PROXY_URL:-direct}" | sed -E 's|//[^/@ ]*@|//***@|')"
  say ok "$(tx 'The OpenCode desktop app is running. Close it to come back here.')"
  wait "$pid"
}
# v0.3.3: line_class <log line>: prints noop (checked first), rotate or ask; nothing when no list matches
line_class(){
  if printf '%s' "$1" | grep -Eiq "$PAT_NOOP"; then echo noop
  elif printf '%s' "$1" | grep -Eiq "$PAT_ROTATE"; then echo rotate
  elif printf '%s' "$1" | grep -Eiq "$PAT_ASK"; then echo ask; fi
}
# limit_hit <new log text>: 0 = rotate now, 2 = ask the user first (not asked in the last 10 minutes), 1 = nothing. Every classified line is logged
limit_hit(){
  local l c act ask=1 now; now=$(date +%s)
  while IFS= read -r l; do
    # an old limit line from an earlier run stays in the shared log: skip lines stamped before this start
    ts=$(printf '%s' "$l" | sed -nE 's/.*timestamp=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/p')
    [ -n "$ts" ] && [ -n "${LIMIT_T0:-}" ] && [[ $ts < $LIMIT_T0 ]] && continue
    c=$(line_class "$l"); [ -n "$c" ] || continue
    act=ignore
    case $c in
      rotate) act=rotate;;
      ask) if [ $(( now - $(cat "$ASK_LAST" 2>/dev/null || echo 0) )) -ge 600 ]; then act=ask; ask=0; else act=ignore-cooldown; fi;;
    esac
    log "watch: category=$c action=$act line=${l:0:160}"
    [ "$act" = rotate ] && return 0
  done < <(printf '%s\n' "$1" | grep -Ei 'level=ERROR')
  [ "$ask" = 0 ] && return 2
  return 1
}
# ask_rotate: the rate limit question, 60 s, no answer = no. Terminal in normal mode while it waits
ask_rotate(){
  local ans=""
  printf '\n%s%s' "$MARG" "$(tx 'Rate limit detected. Rotate the IP now? [y/N] ')"
  stty echo icanon 2>/dev/null
  IFS= read -t 60 -r ans; stty -echo -icanon 2>/dev/null; printf '\n'
  log "rate limit: asked, answer='${ans:-timeout/empty}'"
  [[ ${ans,,} == s || ${ans,,} == si || ${ans,,} == sí || ${ans,,} == y || ${ans,,} == yes ]]
}
# v0.3.3: anti-loop. 0 and records the rotation when fewer than 5 happened in the last 30 minutes
rot_gate(){
  local now t keep=(); now=$(date +%s)
  if [ -f "$ROT_LOG" ]; then while read -r t; do [[ $t =~ ^[0-9]+$ ]] && [ $(( now - t )) -lt 1800 ] && keep+=("$t"); done < "$ROT_LOG"; fi
  [ "${#keep[@]}" -ge 5 ] && return 1
  keep+=("$now"); printf '%s\n' "${keep[@]}" > "$ROT_LOG"
}
watch_log(){ # background: on a limit line, flags LIMIT_FLAG and stops the TUI
  local start=$1 cur="" pos=0 f size hit
  # sizes at start: a log that only grows (the desktop app appends to opencode.log) is read from there, not from its old limit lines
  local -A base; for f in "$DATA_DIR"/log/*.log; do [ -f "$f" ] && base[$f]=$(stat -c%s "$f"); done
  LIMIT_T0=$(date -u -d "@$start" +%Y-%m-%dT%H:%M:%S)  # only log lines stamped after this start count (the log is shared)
  while sleep 2; do
    f=$(ls -t "$DATA_DIR"/log/*.log 2>/dev/null | head -n1)
    [ -n "$f" ] || continue
    if [ "$f" != "$cur" ]; then
      cur=$f
      if [ "$(stat -c%Y "$f")" -ge "$start" ]; then pos=${base[$f]:-0}; else pos=$(stat -c%s "$f"); fi
    fi
    size=$(stat -c%s "$f")
    if [ "$size" -gt "$pos" ]; then
      limit_hit "$(tail -c +$(( pos + 1 )) "$f")"; hit=$?
      if [ "$hit" = 2 ]; then  # v0.3.3: rate limit: stop the TUI, run_session asks (the TUI owns the terminal while it runs)
        date +%s > "$ASK_LAST"; : > "$ASK_FLAG"; stop_opencode; exit 0
      elif [ "$hit" = 0 ]; then
        # v0.3.3: 5 rotations in 30 minutes is a loop: stop watching, run_session tells the user
        if ! rot_gate; then log 'watcher stopped: 5 rotations in the last 30 minutes'; : > "$STATE_DIR/watch.stopped"; exit 0; fi
        : > "$LIMIT_FLAG"; log "limit line seen in $(basename "$f")"
        stop_opencode
        exit 0
      fi
      pos=$size
    fi
  done
}
resume_run(){ # sends RESUME_MSG to the chat, bounded by RESUME_TIMEOUT. 2 = the new IP is limited too
  local folder=$1 out="$STATE_DIR/resume.out" err="$STATE_DIR/resume.err" rc
  # desktop app: restarted, not resumed (as on Windows); "run -c" in this folder could continue a chat that is not the app's
  [ -n "${APP_EXE:-}" ] && return 0
  local auto=(); [ "$RESUME_AUTO" = 1 ] && auto=(--auto)
  oc_runner; export_proxy
  local msg=$RESUME_MSG
  [ "$RESUME_MODE" = custom ] && [ -n "$RESUME_TEXT" ] && msg=$RESUME_TEXT
  log_resume "${RUNNER[*]} run ${auto[*]} -c <message>"  # v0.3.3
  ( cd "$folder" && timeout -k 5 "$RESUME_TIMEOUT" "${RUNNER[@]}" run "${auto[@]}" -c "$msg" ) >"$out" 2>"$err"
  rc=$?
  if grep -Eiq "$OC_PAT|usage limit|rate limit|out of usage|insufficient credits|payment required" "$out" "$err" 2>/dev/null; then return 2; fi
  return $rc
}
# ---- one running OpenCode per launcher window: OC_OTHER_WINDOW decides when another one is already open
LOCK="$STATE_DIR/session.lock"  # "pid starttime" of the launcher that runs OpenCode now
other_open(){ # 0 = another live launcher holds the lock
  local p st
  [ -s "$LOCK" ] || return 1
  read -r p st < "$LOCK"
  [[ $p =~ ^[0-9]+$ ]] && [ "$p" != "$$" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  [ -z "$st" ] || [ "$(pid_start "$p")" = "$st" ]
}
lock_take(){ printf '%s %s\n' "$$" "$(pid_start $$)" > "$LOCK"; }
lock_free(){ local p; [ -s "$LOCK" ] && read -r p _ < "$LOCK" && [ "$p" = "$$" ] && rm -f "$LOCK"; return 0; }
other_window_check(){ # 0 = go on, 1 = stop. Auto never asks: ASK opens anyway
  local choice=$OC_OTHER_WINDOW
  other_open || return 0
  [ "$OPT_AUTO" = 1 ] && [ "$choice" = ASK ] && choice=OPEN
  if [ "$choice" = ASK ]; then
    reset_items; HEAD=("${TH[warn]}|$(tx 'OpenCode is already open in another window.')" ""); SHOW_BANNER=0
    item "$(tx 'Close it and continue')" '' 'Stop the OpenCode of the other window, then start this one.'
    item "$(tx 'Open anyway')" '' 'Start this one next to the other.'
    item "$(tx 'Exit')" '' 'Do nothing.'
    SEL=0; menu 'OpenCode Infinite'
    case $MRES in 0) choice=CLOSE;; 1) choice=OPEN;; *) return 1;; esac
  fi
  if [ "$choice" = CLOSE ]; then log 'other window: its OpenCode was closed (OC_OTHER_WINDOW=CLOSE)'; stop_opencode
  else log 'other window: opened anyway'; fi
  return 0
}
run_session(){ # run_session <folder> [opencode args...]: checks the window rule, holds the lock while OpenCode runs
  other_window_check || return 1
  lock_take; run_session_inner "$@"; local rc=$?
  lock_free; return $rc
}
run_session_inner(){ # run_session_inner <folder> [opencode args...]
  local folder=$1; shift
  local cont="" start rc wpid
  [ "${START_CONTINUE:-0}" = 1 ] && cont=1; START_CONTINUE=0
  [ -d "$folder" ] || { say err "folder not found: $folder"; return 1; }
  printf '%s' "$folder" > "$STATE_DIR/last_folder"  # Auto opens this folder next time
  [ -x "$OC_REAL" ] || { say err 'opencode is not set up. Run "Connect with opencode" first.'; return 1; }
  APP_EXE=""  # set = desktop mode for this session; the CLI is still needed for the probe
  if [ "$OC_MODE_DEFAULT" = DESKTOP ] && ! APP_EXE=$(app_find); then
    log "desktop app not found (OC_APP=${OC_APP:-empty}, /opt/OpenCode, PATH)"
    confirm "$(tx 'Desktop app not found. Start OpenCode in this terminal instead?')" || return 1
  fi
  if [ "${ROUTE_READY:-0}" != 1 ] && ! egress_up; then
    say err "$EGRESS did not come up. Check the egress, then try again."
    log "egress $EGRESS failed to start"; return 1
  fi
  oc_runner
  while :; do
    rm -f "$LIMIT_FLAG"
    token_guard
    export_proxy
    start=$(date +%s); wpid=""
    [ -n "$cont" ] && [ -z "$APP_EXE" ] && log_resume "${RUNNER[*]} -c" "$@"  # v0.3.3
    rm -f "$STATE_DIR/watch.stopped"
    if [ "$WATCH" = 1 ]; then watch_log "$start" & wpid=$!; WPID=$wpid; fi
    if [ -n "$APP_EXE" ]; then app_run "$folder" "$APP_EXE"; rc=$?
    # v0.3.3: exec keeps the PID, saved so stop_opencode kills only this one
    else ( cd "$folder" && echo $BASHPID > "$OC_PIDS" && exec "${RUNNER[@]}" ${cont:+-c} "$@" ); rc=$?; fi
    : > "$OC_PIDS"
    [ -n "$wpid" ] && kill "$wpid" 2>/dev/null; WPID=
    [ -f "$STATE_DIR/watch.stopped" ] && { say warn 'Watcher stopped: 5 rotations in 30 minutes. Not rotating again by itself; use New IP from the menu.'; rm -f "$STATE_DIR/watch.stopped"; }
    log "opencode exited rc=$rc"
    if [ -f "$ASK_FLAG" ]; then  # v0.3.3: rate limit. Yes = the limit path below; no = the same chat reopens on the same IP
      rm -f "$ASK_FLAG"
      if [ "$OPT_AUTO" = 1 ] || ask_rotate; then  # Auto rotates without asking
        if rot_gate; then : > "$LIMIT_FLAG"; else say warn '5 rotations in 30 minutes: not rotating.'; cont=1; continue; fi
      else cont=1; continue; fi
    fi
    if [ ! -f "$LIMIT_FLAG" ]; then
      case $rc in 0|130|143) return 0;; esac # clean exit or Ctrl+C / kill: not a crash
      crash_retry "$rc"; case $? in
        0) resume_run "$folder" >/dev/null 2>&1; cont=1; continue;;
        1) [ "$OPT_AUTO" = 1 ] || pause; return 1;;
        *) return 0;;
      esac
    fi
    rm -f "$LIMIT_FLAG"; stop_opencode
    if [ "$AUTO_ROTATE" != 1 ]; then say warn "limit hit. Pick New IP from the menu."; return 0; fi
    say warn "limit hit: rotating the IP and resuming the chat..."
    if ! egress_new; then say err "no new route after $ROTATE_TRIES_MAX tries."; return 1; fi
    say ok "new route: $(current_ip)"
    resume_run "$folder"; rc=$?
    if [ "$rc" = 2 ] || [ "$rc" = 124 ]; then say warn "the new IP is limited too. Rotating again."; continue; fi
    cont="--continue"
  done
}
# after_close: OpenCode closed on its own. ON_CLOSE decides between the menu and quitting
after_close(){ # ask: R = new IP and resume the chat, M = menu, Q = quit. The keys come from Settings > Shortcuts
  local folder=$1 k
  [ "$ON_CLOSE" = quit ] && { QUIT=1; return 0; }
  say warn "OpenCode closed. ${KEY_ROTATE^^} = new IP and resume, ${KEY_MENU^^} = menu, ${KEY_QUIT^^} = quit."
  IFS= read -rsn1 k; k=${k^^}
  if [ "$k" = "${KEY_ROTATE^^}" ]; then
    if egress_new; then say ok "new route: $(current_ip)"; resume_run "$folder"; ROUTE_READY=1 START_CONTINUE=1 run_session "$folder" && after_close "$folder"  # v0.3.3: ROUTE_READY=1, the chat resumes on the route just made, not a new pick
    else say err 'no new route.'; pause; fi
  elif [ "$k" = "${KEY_QUIT^^}" ]; then QUIT=1
  fi
}

# ---------------------------------------------------------------- setup: dependencies, shims
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"  # opencode-infinite'
ensure_path(){
  case ":$PATH:" in *":$BIN_DIR:"*) return;; esac
  grep -q 'opencode-infinite' "$HOME/.bashrc" 2>/dev/null || printf '%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
}
fix_old_shim(){ # v2.52 and older replaced $BIN_DIR/opencode with a launcher shim: put the real command back. A real command is never touched
  local p="$BIN_DIR/opencode"
  { [ -e "$p" ] || [ -L "$p" ]; } || return 0
  grep -q 'opencode-infinite' "$p" 2>/dev/null || return 0
  rm -f "$p"
  [ -n "$OC_LINK" ] && ln -sfn "$OC_LINK" "$p"
  if [ ! -e "$p" ]; then rm -f "$p"; say warn 'opencode was replaced by an old launcher shim and could not be restored. Run opencodeinf: it installs opencode again.'; fi
  if find_real_opencode; then cfg_set OC_REAL "$OC_REAL"; cfg_set OC_LINK "$OC_LINK"; fi
}
write_shims(){ # the commands. opencode itself is never written: it stays the real one
  mkdir -p "$BIN_DIR" "$APP_DIR"
  cp "$SELF" "$APP_DIR/opencode-infinite.sh"
  oc_runner
  fix_old_shim
  write_bin_cmds
}
# write_bin_cmds: opencodeinf (menu), opencodeoc (plain OpenCode) and the direct commands opencode-warp, -tor, -proxy. Needs oc_runner first
write_bin_cmds(){
  local app="$APP_DIR/opencode-infinite.sh" p
  printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$app" > "$BIN_DIR/opencodeinf"
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(printf '%q ' "${RUNNER[@]}")" > "$BIN_DIR/opencodeoc"
  for p in warp tor proxy; do
    printf '#!/usr/bin/env bash\nexec bash "%s" --preset %s --here --same-ip --quiet -- "$@"\n' "$app" "$p" > "$BIN_DIR/opencode-$p"
  done
  chmod +x "$BIN_DIR/opencodeinf" "$BIN_DIR/opencodeoc" "$BIN_DIR/opencode-warp" "$BIN_DIR/opencode-tor" "$BIN_DIR/opencode-proxy"
}
find_real_opencode(){ # sets OC_REAL and OC_LINK to the Linux opencode, never a Windows one (/mnt/...) or our own command
  local d p
  for d in ${PATH//:/ } "$HOME/.local/bin" "$HOME/.opencode/bin" "${XDG_BIN_DIR:-}" "$HOME/.local/lib/node_modules/opencode-ai/bin"; do
    case $d in /mnt/*) continue;; esac
    for p in "$d"/opencode "$d"/opencode.exe; do
      [ -x "$p" ] || continue
      grep -q 'opencode-infinite' "$p" 2>/dev/null && continue
      OC_LINK=$(readlink "$p" 2>/dev/null || true)
      OC_REAL=$(readlink -f "$p"); return 0
    done
  done
  return 1
}
INSTALL_LOG="$STATE_DIR/install.log"
SUDO=()
sudo_ok(){ # root needs nothing; anyone else only with sudo that asks nothing (sudo -n). This script never asks for a password.
  if [ "$(id -u)" -eq 0 ]; then SUDO=(); return 0; fi
  command -v sudo >/dev/null && sudo -n true 2>/dev/null && { SUDO=(sudo -n); return 0; }
  return 1
}
# pkg_mgr: apt, dnf, pacman or zypper, empty when none of them is here
pkg_mgr(){
  command -v apt-get >/dev/null && { echo apt; return 0; }
  command -v dnf >/dev/null && { echo dnf; return 0; }
  command -v pacman >/dev/null && { echo pacman; return 0; }
  command -v zypper >/dev/null && echo zypper
  return 0
}
pkg_refresh(){
  case $(pkg_mgr) in
    apt) with_tty "${SUDO[@]}" apt-get update;;
    dnf) with_tty "${SUDO[@]}" dnf makecache;;
    pacman) with_tty "${SUDO[@]}" pacman -Sy --noconfirm;;
    zypper) with_tty "${SUDO[@]}" zypper --non-interactive refresh;;
  esac >>"$INSTALL_LOG" 2>&1
}
pkg_install(){
  case $(pkg_mgr) in
    apt) with_tty "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@";;
    dnf) with_tty "${SUDO[@]}" dnf install -y "$@";;
    pacman) with_tty "${SUDO[@]}" pacman -S --needed --noconfirm "$@";;
    zypper) with_tty "${SUDO[@]}" zypper --non-interactive install "$@";;
  esac >>"$INSTALL_LOG" 2>&1
}
warp_repo(){ # Cloudflare's own repo for apt and dnf; pacman has none, the client is in the AUR
  local code
  case $(pkg_mgr) in
    apt) code=$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
         [ -n "$code" ] || return 1
         pkg_install ca-certificates gnupg || return 1
         curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | with_tty "${SUDO[@]}" gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg || return 1
         printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$code" \
           | with_tty "${SUDO[@]}" tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null;;
    dnf) curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | with_tty "${SUDO[@]}" tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null;;
    *) return 1;;
  esac
}
install_warp(){ # the client, and its service where systemd runs
  warp_repo && pkg_refresh && pkg_install cloudflare-warp || { say err 'WARP was not installed. Arch: install cloudflare-warp-bin from the AUR. Others: install cloudflare-warp by hand.'; return 1; }
  command -v systemctl >/dev/null && with_tty "${SUDO[@]}" systemctl enable --now warp-svc >>"$INSTALL_LOG" 2>&1
  return 0
}
apply_setup(){ # shims, saved paths and PATH, the same whether the menu or the automatic start ran it
  write_shims
  cfg_set OC_REAL "$OC_REAL"; cfg_set OC_LINK "$OC_LINK"; cfg_set SETUP_DONE 1
  ensure_path
  log "setup done egress=$EGRESS real=$OC_REAL"
}
install_opencode(){ # npm into ~/.local first, then the official installer; neither needs root
  command -v npm >/dev/null && timeout 900 npm i -g --prefix "$HOME/.local" opencode-ai >>"$INSTALL_LOG" 2>&1
  find_real_opencode && return 0
  curl -fsSL -m 120 https://opencode.ai/install -o "$STATE_DIR/opencode-install.sh" \
    && XDG_BIN_DIR="$HOME/.local/bin" bash "$STATE_DIR/opencode-install.sh" >>"$INSTALL_LOG" 2>&1
  find_real_opencode && return 0
  say err "opencode could not be installed. Log: $INSTALL_LOG"; return 1
}
ensure_deps(){ # installs what is missing, each step on its own: a failed step never stops the next one
  local m want=() warp_need=0 priv_new=0 did=0
  m=$(pkg_mgr)
  command -v warp-cli >/dev/null || warp_need=1
  command -v curl >/dev/null || want+=(curl)
  command -v tor >/dev/null || [ "$TOR_AUTO_INSTALL" = 0 ] || want+=(tor)
  command -v privoxy >/dev/null || [ "$TOR_AUTO_INSTALL" = 0 ] || { want+=(privoxy); priv_new=1; }
  command -v jq >/dev/null || want+=(jq)
  command -v node >/dev/null || want+=(nodejs)
  command -v npm >/dev/null || want+=(npm)
  command -v xdg-user-dir >/dev/null || want+=(xdg-user-dirs)
  local oc_need=0 what
  find_real_opencode || oc_need=1
  if [ "$warp_need" = 1 ] || [ ${#want[@]} -gt 0 ] || [ "$oc_need" = 1 ]; then
    # v2.60.1: ask before anything is installed. Auto and quiet runs never install on their own.
    what="${want[*]}"; [ "$warp_need" = 1 ] && what="WARP $what"; [ "$oc_need" = 1 ] && what="$what opencode"
    if [ "$OPT_AUTO" = 1 ] || [ "${OPT_QUIET:-0}" = 1 ]; then say warn "missing, not installed in auto or quiet mode: ${what# }"; return 0; fi
    if ! confirm "Install what is missing: ${what# }?"; then say warn "skipped, nothing installed: ${what# }"; return 0; fi
  fi
  if [ "$warp_need" = 1 ] || [ ${#want[@]} -gt 0 ]; then
    did=1
    if [ -z "$m" ]; then say err "no apt, dnf, pacman or zypper here. Install by hand: WARP ${want[*]}"
    elif sudo_ok; then
      say warn "installing what is missing. Keep this window open. Log: $INSTALL_LOG"
      pkg_refresh
      if [ ${#want[@]} -gt 0 ]; then pkg_install "${want[@]}" || say err 'some packages failed. The log has the details.'; fi
      if [ "$priv_new" = 1 ] && command -v systemctl >/dev/null; then with_tty "${SUDO[@]}" systemctl disable --now privoxy >>"$INSTALL_LOG" 2>&1; fi
      if [ "$warp_need" = 1 ]; then install_warp; fi
    else say err "no sudo for this user. Install by hand: WARP ${want[*]}"; fi
  fi
  if ! find_real_opencode; then did=1; say warn 'installing opencode...'; install_opencode; fi
  if [ "$SETUP_DONE" != 1 ] && find_real_opencode; then apply_setup; fi
  [ "$did" = 1 ] && [ "${OPT_QUIET:-0}" != 1 ] && [ "$OPT_AUTO" != 1 ] && pause
  return 0
}
connect_setup(){
  local -a opts=(ASK WARP TOR PROXY NONE)
  local -a labels=('ASK (pick at each start)' 'WARP (Cloudflare proxy, rotation)' 'TOR (Tor through a privoxy bridge)' 'PROXY (free HTTP list)' 'NONE (direct)')
  local i
  reset_items; HEAD=(); SHOW_BANNER=0
  for i in 0 1 2 3 4; do item "$(tx "${labels[i]}")" "$([ "$OC_EGRESS_DEFAULT" = "${opts[i]}" ] && echo current)" "Default route for OpenCode: ${opts[i]}. The proxy applies only to the OpenCode process."; done
  item "$(tx 'Cancel')" '' 'Leave the setup without changing anything.'
  SEL=0; for i in 0 1 2 3 4; do [ "$OC_EGRESS_DEFAULT" = "${opts[i]}" ] && SEL=$i; done
  menu "$(tx 'Connect with opencode')" ''
  [ "$MRES" -ge 0 ] && [ "$MRES" -lt 5 ] || return 0
  OC_EGRESS_DEFAULT=${opts[MRES]}; EGRESS=$OC_EGRESS_DEFAULT; [ "$EGRESS" = ASK ] && EGRESS=NONE
  OC_REAL=""; OC_LINK=""
  find_real_opencode
  if [ -z "$OC_REAL" ]; then say err "opencode was not found. Install it first: npm i -g opencode-ai"; pause; return 0; fi
  [ -f "$SELF" ] || { say err 'run the script from a file, not from a pipe or process substitution'; pause; return 0; }
  cfg_set OC_EGRESS_DEFAULT "$OC_EGRESS_DEFAULT"; apply_setup
  say ok "setup done: opencode, opencodeinf and opencodeoc are in $BIN_DIR"
  pause
  load_cfg
}
make_shortcut(){
  local dir="$HOME/.local/share/applications" f desk
  mkdir -p "$dir"; f="$dir/opencode-infinite.desktop"
  printf '[Desktop Entry]\nType=Application\nName=OpenCode Infinite\nComment=OpenCode with egress and auto-resume\nExec="%s"\nTerminal=true\nCategories=Development;\n' "$BIN_DIR/opencodeinf" > "$f"
  desk=$(desk_dir); cp "$f" "$desk/opencode-infinite.desktop"; chmod +x "$desk/opencode-infinite.desktop"
  say ok "shortcut: $f and $desk/opencode-infinite.desktop"; pause
}
# v0.3.3: backup_auth: auth.json is copied to $STATE_DIR/backup/auth/<date-time>/ before anything may delete it. 1 = no backup, do not delete
backup_auth(){
  [ -f "$DATA_DIR/auth.json" ] || return 0
  local d stamp; stamp=$(date +%Y%m%d-%H%M%S); d="$STATE_DIR/backup/auth/$stamp"
  (umask 077; mkdir -p "$d") && cp -p "$DATA_DIR/auth.json" "$d/auth.json" && log "auth.json backed up to $d" || { say err "could not back up auth.json to $d: tokens kept"; return 1; }
}
renew_session(){
  confirm 'Close OpenCode, back up auth.json (launcher state folder) and clear the tokens?' || return 0
  stop_opencode
  if [ -f "$DATA_DIR/auth.json" ]; then backup_auth && rm -f "$DATA_DIR/auth.json" && say ok "auth.json backed up in the launcher state folder, tokens cleared"; fi  # not on the Desktop: a copy there is readable by any app and syncs to the cloud
  [ -e "$DATA_DIR/auth.json" ] || drop_snapshot  # v0.3.3: the snapshot goes only when the tokens went
  if egress_new || egress_up; then say ok "new route: $(current_ip)"; else say err "no new route."; fi
  log 'renew done'
  pause
}
uninstall(){
  confirm 'Remove the opencode commands and shortcuts and restore the old opencode command? Settings are kept.' || return 0
  rm -f "$BIN_DIR/opencodeinf" "$BIN_DIR/opencodeoc" "$BIN_DIR/opencode-warp" "$BIN_DIR/opencode-tor" "$BIN_DIR/opencode-proxy"
  rm -f "$HOME/.local/share/applications/opencode-infinite.desktop" "$(desk_dir)/opencode-infinite.desktop"
  if [ -n "$OC_LINK" ]; then fix_old_shim; elif grep -q 'opencode-infinite' "$BIN_DIR/opencode" 2>/dev/null; then rm -f "$BIN_DIR/opencode"; fi
  [ -f "$HOME/.bashrc" ] && sed -i '/opencode-infinite/d' "$HOME/.bashrc"
  cfg_set SETUP_DONE 0
  log 'uninstalled'
  say ok 'removed. The old opencode command is back where it was.'
  pause
  load_cfg
}

cmd_state(){ if [ -x "$BIN_DIR/opencodeinf" ]; then echo installed; else echo 'not installed'; fi; }
# Commands on their own (not tied to Connect with opencode): opencodeinf and opencodeoc in $BIN_DIR, folder on PATH
commands_install(){ # commands_install [quiet]: quiet = --install, no pause
  local q=${1:-}
  [ -f "$SELF" ] || { say err 'run the script from a file, not from a pipe or process substitution'; [ "$q" = quiet ] || pause; return 1; }
  OC_REAL=""; OC_LINK=""
  if ! find_real_opencode; then say err "opencode was not found. Install it first: npm i -g opencode-ai"; [ "$q" = quiet ] || pause; return 1; fi
  mkdir -p "$BIN_DIR" "$APP_DIR"
  cp "$SELF" "$APP_DIR/opencode-infinite.sh"; oc_runner
  write_bin_cmds
  cfg_set OC_REAL "$OC_REAL"; cfg_set OC_LINK "$OC_LINK"
  ensure_path
  log 'commands installed'
  say ok "commands installed in $BIN_DIR: opencodeinf, opencodeoc, opencode-warp, opencode-tor, opencode-proxy"
  [ "$q" = quiet ] || pause
  return 0
}
commands_remove(){
  confirm 'Remove the opencode-infinite commands (opencodeinf, opencodeoc, opencode-warp/-tor/-proxy)? The opencode command and your settings are kept.' || return 0
  rm -f "$BIN_DIR/opencodeinf" "$BIN_DIR/opencodeoc" "$BIN_DIR/opencode-warp" "$BIN_DIR/opencode-tor" "$BIN_DIR/opencode-proxy"
  if [ -z "$(ls -A "$BIN_DIR" 2>/dev/null)" ] && [ -f "$HOME/.bashrc" ]; then sed -i '/opencode-infinite/d' "$HOME/.bashrc"; fi
  log 'commands removed'
  say ok 'commands removed. The folder stays on PATH while other files are in it.'
  pause
}

# ---------------------------------------------------------------- deep reset and restore
archive_file(){ # copy, compare sizes, delete the original only when they match
  [ -f "$1" ] || return 1
  cp -p "$1" "$2" || return 1
  local s1 s2; s1=$(stat -c%s "$1" 2>/dev/null); s2=$(stat -c%s "$2" 2>/dev/null)
  # v2.60: an empty size (stat failed) never counts as a match
  if [ -z "$s1" ] || [ "$s1" != "$s2" ]; then rm -f "$2"; return 1; fi
  rm -f "$1"
}
deep_reset(){
  local desk stamp target f moved=0
  confirm 'Close every OpenCode, move the chats to the Desktop and clear the saved tokens?' || return 0
  stop_opencode
  desk=$(desk_dir); stamp=$(date +%Y%m%d-%H%M%S)
  target="$desk/opencode_chats_archiviate/$stamp"
  mkdir -p "$target"
  say warn "archiving chats to: $target"
  if [ -d "$DATA_DIR/storage" ] && mv "$DATA_DIR/storage" "$target/storage"; then moved=1; fi
  for f in opencode.db opencode.db-wal opencode.db-shm; do archive_file "$DATA_DIR/$f" "$target/$f" && moved=1; done
  # v2.60: tokens never go to the Desktop in plain text. backup_auth keeps a private copy (umask 077) under STATE_DIR.
  if [ -f "$DATA_DIR/auth.json" ] && backup_auth && rm -f "$DATA_DIR/auth.json"; then say ok 'auth.json backed up privately and cleared.'; moved=1; fi
  # v0.3.3: snapshot and cache go only when the tokens were backed up and removed
  if [ ! -e "$DATA_DIR/auth.json" ]; then drop_snapshot; [ -n "$HOME" ] && rm -rf "$HOME/.cache/opencode"; fi
  if [ "$moved" = 0 ]; then rmdir "$target" 2>/dev/null; say warn 'nothing to archive.'
  else say ok 'archived. Tokens cleared.'; log "deep reset to $target"; fi
  pause
}
restore_chats(){ # the chats in place are moved aside to the Desktop, never deleted
  local root desk f keep src d i picks=()
  desk=$(desk_dir); root="$desk/opencode_chats_archiviate"
  for d in "$root"/*/; do [ -d "$d" ] && picks+=("${d%/}"); done
  [ ${#picks[@]} -gt 0 ] || { say warn 'no archived chats found.'; pause; return 0; }
  local -a newest; mapfile -t newest < <(printf '%s\n' "${picks[@]}" | sort -r)
  reset_items; HEAD=(); SHOW_BANNER=0
  for d in "${newest[@]}"; do item "$(basename "$d")" '' "$d"; done
  item "$(tx 'Back')" '' 'Return to the chats menu.'
  menu "$(tx 'Restore chats')"
  [ "$MRES" -ge 0 ] && [ "$MRES" -lt ${#newest[@]} ] || return 0
  src=${newest[MRES]}
  [ -f "$src/opencode.db" ] || [ -d "$src/storage" ] || { say err 'this archive has no chats.'; pause; return 0; }
  confirm "Restore the chats from $(basename "$src")? Auth is not restored." || return 0
  stop_opencode
  keep="$desk/opencode_chats_before_restore/$(date +%Y%m%d-%H%M%S)-$RANDOM"
  mkdir -p "$keep"
  for i in opencode.db opencode.db-wal opencode.db-shm; do [ -e "$DATA_DIR/$i" ] && mv "$DATA_DIR/$i" "$keep/$i"; done
  [ -d "$DATA_DIR/storage" ] && mv "$DATA_DIR/storage" "$keep/storage"
  for f in opencode.db opencode.db-wal opencode.db-shm; do [ -e "$src/$f" ] && cp -p "$src/$f" "$DATA_DIR/$f"; done
  [ -d "$src/storage" ] && cp -rp "$src/storage" "$DATA_DIR/storage"
  say ok "chats restored. The old ones are in $keep"
  log "restored $src"
  pause
}
chats_menu(){
  while :; do
    reset_items; SHOW_BANNER=0; HEAD=()
    item "$(tx 'Deep reset')" '' 'Close OpenCode, move the chats to the Desktop, clear the tokens. Asks first, archives before deleting.' '' err
    item "$(tx 'Restore chats')" '' 'Put back the chats of an archived deep reset. Current chats are moved aside, never deleted.'
    item "$(tx 'Back')" '' 'Return to the main menu.'
    menu "$(tx 'Chats')"
    case $MRES in
      0) deep_reset;;
      1) restore_chats;;
      *) return 0;;
    esac
  done
}

# ---------------------------------------------------------------- updates
update_launcher(){ # newest GitLab release only; the file must match SHA256SUMS at that tag. This script is backed up first
  local tag sum new
  tag=$(curl -fsSL -m 10 "https://gitlab.com/api/v4/projects/88367491/releases?order_by=released_at&sort=desc&per_page=1" 2>/dev/null | grep -o '"tag_name":"v[0-9]*\.[0-9][0-9.]*"' | head -n1 | cut -d'"' -f4)
  [ -n "$tag" ] || return 0
  sum=$(curl -fsSL -m 10 "$REPO/-/raw/$tag/SHA256SUMS" 2>/dev/null | sed -n 's/^\([0-9a-f]\{64\}\) [ *]opencode-infinite\.sh$/\1/p' | head -n1)
  [ -n "$sum" ] || return 0
  curl -fsSL -m 30 -o "$SELF.new" "$REPO/-/raw/$tag/opencode-infinite.sh" 2>/dev/null || { rm -f "$SELF.new"; return 0; }
  [ "$(sha256sum "$SELF.new" | cut -d' ' -f1)" = "$sum" ] || { rm -f "$SELF.new"; say err 'the downloaded launcher failed its SHA-256 check. Nothing changed.'; pause; return 0; }
  new=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SELF.new" | head -n1)
  { [ -n "$new" ] && [ "$new" != "$VERSION" ] && [ "$(printf '%s\n%s\n' "$VERSION" "$new" | sort -V | tail -n1)" = "$new" ]; } || { rm -f "$SELF.new"; return 0; }
  confirm "Update the launcher from $VERSION to $new? This script is backed up first." || { rm -f "$SELF.new"; return 0; }
  bash -n "$SELF.new" || { rm -f "$SELF.new"; say err 'the new copy failed the syntax check. Nothing changed.'; pause; return 0; }
  cp "$SELF" "$SELF.bak" && mv "$SELF.new" "$SELF" && chmod +x "$SELF" || { say err 'could not replace the script.'; pause; return 0; }
  [ "$SETUP_DONE" = 1 ] && [ -x "$OC_REAL" ] && write_shims
  log "launcher updated $VERSION -> $new"
  stty sane 2>/dev/null
  exec bash "$SELF" "${ARGS[@]}"
}
update_opencode(){ # offers a newer opencode through npm
  local cur latest
  [ -x "$OC_REAL" ] || return 0
  oc_runner
  cur=$("${RUNNER[@]}" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  latest=$(curl -fsS -m 15 "$OC_API_BASE/cli/opencode/" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  [ -n "$latest" ] || latest=$(timeout 20 npm view opencode-ai version 2>/dev/null | head -n1)
  [ -n "$cur" ] && [ -n "$latest" ] && [ "$cur" != "$latest" ] || return 0
  [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -n1)" = "$latest" ] || return 0
  confirm "Update opencode from $cur to $latest through npm?" || return 0
  with_tty timeout 600 npm i -g --prefix "$HOME/.local" "opencode-ai@$latest" || say err 'npm update failed.'
  say ok "opencode update step done (was $cur)."; log "opencode update $cur -> $latest"; pause
}
check_updates(){ # auto = at start (silent when offline or equal); manual = from the support menu
  [ "$UPDATE_CHECK" = 1 ] && update_launcher
  update_opencode
  [ "$1" = manual ] && { say ok 'checked. Nothing newer was offered.'; pause; }
  return 0
}

# ---------------------------------------------------------------- support
support_report(){
  local dir="$STATE_DIR/reports" f
  mkdir -p "$dir"; f="$dir/support-$(date +%Y%m%d-%H%M%S).txt"
  oc_runner
  {
    echo "OpenCode Infinite $VERSION"
    echo "date: $(date -Iseconds)"; echo "kernel: $(uname -a)"; echo "bash: $BASH_VERSION"
    echo "opencode: $("${RUNNER[@]}" --version 2>/dev/null || echo none)"
    echo "warp-cli: $(warp-cli --version 2>/dev/null || echo none)"
    echo "tor: $(tor --version 2>/dev/null | head -n1)"
    echo "jq: $(jq --version 2>/dev/null || echo none)"
    echo "--- config (no tokens)"; grep -v -i 'token\|password' "$CONF" 2>/dev/null
    echo "--- launcher.log (last 200 lines, IPs masked)"
    if [ "$LOG_MASK_IP" = 1 ]; then tail -n 200 "$LOG" 2>/dev/null | sed -E 's/([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/\1.x/g'; else tail -n 200 "$LOG" 2>/dev/null; fi
  } > "$f"
  say ok "support report: $f"
  pause
}

# ---------------------------------------------------------------- auto, direct commands, status, commands menu
# auto_run: no questions. The last folder, the fastest installed route, a new IP, a fresh chat
auto_run(){
  local first m folder; local -a chain=()
  OPT_AUTO=1; ROUTE_READY=0
  [ "$SETUP_DONE" = 1 ] || { say err 'Connect with opencode first (Commands menu).'; return 1; }
  ensure_deps
  first=$(auto_pick); mapfile -t chain < <(auto_chain "$first")  # an array: a command in the loop may read stdin
  for m in "${chain[@]}"; do
    EGRESS=$m
    if egress_new; then ROUTE_READY=1; break; fi
    log "auto: $m gave no new route, trying the next one"
  done
  if [ "$ROUTE_READY" != 1 ]; then say err 'no route came up (WARP, TOR or PROXY). Details in launcher.log.'; return 1; fi
  folder=$(cat "$STATE_DIR/last_folder" 2>/dev/null); [ -d "$folder" ] || folder=$HOME
  log "auto: folder=$folder route=$EGRESS first=$first"
  START_CONTINUE=0; run_session "$folder"
}
auto_home(){ auto_run || pause; OPT_AUTO=0; }  # back to the menu: questions are asked again
# preset_run <warp|tor|proxy> [opencode args]: the direct commands. This folder, no menu. --new-ip rotates first; the default keeps the route
preset_run(){
  local m=${1^^}; shift
  case $m in WARP|TOR|PROXY) ;; *) say err "unknown route: $m (use warp, tor or proxy)"; return 2;; esac
  [ "$SETUP_DONE" = 1 ] || { say err 'Connect with opencode first (Commands menu).'; return 1; }
  EGRESS=$m; OC_MODE_DEFAULT=CLI; OPT_AUTO=0; ROUTE_READY=0
  if [ "$NEWIP" = 1 ]; then egress_new || { say err "no new route on $m."; return 1; }
  else egress_up || { say err "$m did not come up. Check it, then try again."; return 1; }; fi
  ROUTE_READY=1
  run_session "$PWD" "$@"
}
print_help(){
cat <<EOF
OpenCode Infinite $VERSION

  opencodeinf                        the menu
  opencodeinf --auto                 last folder, fastest installed route, new IP, fresh chat. No questions
  opencodeinf --install              write the commands and exit
  opencodeinf --preset NAME          OpenCode on WARP, TOR or PROXY in this folder (NAME = warp, tor, proxy)
  opencodeinf --warp|--tor|--proxy   same as --preset NAME --here --same-ip --quiet
  opencodeinf --run [args]           OpenCode in this terminal on the default route; args go to opencode
  opencodeinf --here                 this folder (presets always use it)
  opencodeinf --same-ip              keep the current route (default for presets)
  opencodeinf --new-ip               get a new IP before OpenCode starts
  opencodeinf --quiet                print only errors
  opencodeinf -- args                everything after -- goes to opencode
  opencodeinf --help                 this text
EOF
}
method_help(){
  case $1 in
    WARP) echo 'Cloudflare WARP. Installing it needs administrator rights (sudo), which this script never asks for.';;
    TOR) echo 'Tor with a privoxy bridge. Installing it needs administrator rights (sudo), which this script never asks for.';;
    PROXY) echo 'A free HTTP proxy list. Nothing to install.';;
  esac
}
# install_method <WARP|TOR>: Enter on a missing route. Installs only with sudo -n (no password prompt).
install_method(){
  local had_privoxy
  case $1 in
    WARP) sudo_ok && install_warp;;
    TOR) had_privoxy=$(command -v privoxy)
         if sudo_ok; then pkg_refresh; pkg_install tor privoxy
           [ -z "$had_privoxy" ] && command -v systemctl >/dev/null && with_tty "${SUDO[@]}" systemctl disable --now privoxy >>"$INSTALL_LOG" 2>&1
         fi;;
  esac
  if method_installed "$1"; then say ok "$1 is installed."; else say err "$1 was not installed. Log: $INSTALL_LOG"; fi
  pause
}
# status_menu: which routes are installed and the last measured time of each. Enter on a missing one installs it
status_menu(){
  local -a names=(WARP TOR PROXY); local m st ms
  while :; do
    reset_items; SHOW_BANNER=0; HEAD=()
    for m in "${names[@]}"; do
      if method_installed "$m"; then st=installed; else st='not installed'; fi
      ms=$(method_ms "$m"); [ -n "$ms" ] && st="$st, last route ${ms} ms"
      item "$m" "$st" "$(method_help "$m")"
    done
    item "$(tx 'Back')" '' 'Return to the home screen.'
    menu "$(tx 'Status')"
    case $MRES in
      0|1|2) m=${names[MRES]}; method_installed "$m" || install_method "$m";;
      *) return 0;;
    esac
  done
}
# commands_menu: the commands, the Connect setup, uninstall
commands_menu(){
  local act
  while :; do
    reset_items; SHOW_BANNER=0; HEAD=(); local -a acts=()
    item "$(tx 'Install commands')" "$(tx "$(cmd_state)")" 'Writes opencodeinf, opencodeoc and opencode-warp, opencode-tor, opencode-proxy into ~/.local/bin and puts that folder on PATH. Does not need Connect with opencode.'; acts+=(commands_install)
    item "$(tx 'Remove commands')" "$(tx "$(cmd_state)")" 'Deletes the opencode-infinite commands. Asks first.' '' err; acts+=(commands_remove)
    if [ "$SETUP_DONE" = 1 ]; then
      item "$(tx 'Connect with opencode')" "Configured - $OC_EGRESS_DEFAULT" 'Connection and commands. Run it again to change the default route.'; acts+=(connect_setup)
      item "$(tx 'Uninstall')" '' 'Removes the opencode commands and shortcuts and restores the old opencode command. Asks first.' '' err; acts+=(uninstall)
    else
      item "$(tx 'Connect with opencode')" 'Not configured' 'Guided setup: installs what is missing, then WARP, Tor, a proxy list or direct. Creates opencode, opencodeinf and opencodeoc.' '' warn; acts+=(connect_setup)
    fi
    item "$(tx 'Back')" '' 'Return to the home screen.'; acts+=(back)
    menu "$(tx 'Commands')"
    [ "$MRES" -ge 0 ] || return 0
    act=${acts[MRES]}
    [ "$act" = back ] && return 0
    "$act"
    [ "$QUIT" = 1 ] && return 0
  done
}

# ---------------------------------------------------------------- screens
main_menu(){ # the screen after Launch: pick a route and start
  local folder=$1
  while :; do
    reset_items; SHOW_BANNER=0
    HEAD=("${TH[acc]}|  folder: $folder" "${TH[acc]}|  egress: $EGRESS")
    item "$(tx 'New IP and start OpenCode')" '' 'Hunt for a new IP (target and probe), then open OpenCode. Chats stay as they are.'
    item "$(tx 'Start OpenCode')" '' 'Open OpenCode on the current route.'
    item "$(tx 'Change IP (test)')" '' 'Rotate the connection only, without opening OpenCode.'
    item "$(tx 'Chats')" '' 'Deep reset (chats to the Desktop) or restore an archived set.'
    item "$(tx 'Back')" '' 'Return to the home screen.'
    menu "$(tx 'Main menu')"
    case $MRES in
      0) ROUTE_READY=0
         if egress_new; then ROUTE_READY=1; run_session "$folder" && after_close "$folder"
         else say err 'no new route.'; pause; fi;;
      1) ROUTE_READY=0; run_session "$folder" && after_close "$folder";;
      2) if egress_new; then say ok "new route: $(current_ip)"; else say err 'no new route.'; fi; pause;;
      3) chats_menu;;
      *) return 0;;
    esac
    [ "$QUIT" = 1 ] && return 0
  done
}
pick_egress(){ # ASK default: the route for this run only, nothing is saved
  local -a opts=(WARP TOR PROXY NONE) i
  reset_items; HEAD=(); SHOW_BANNER=0
  for i in 0 1 2 3; do item "${opts[i]}" '' "Use ${opts[i]} for this run."; done
  item "$(tx 'Cancel')" '' 'Go back.'
  SEL=0; menu "$(tx 'Route for this run')"
  [ "$MRES" -ge 0 ] && [ "$MRES" -lt 4 ] || return 1
  EGRESS=${opts[MRES]}
}
launch(){
  ask 'Folder to work in' "$PWD" || return 0
  [ -d "$ANSWER" ] || { say err "not a folder: $ANSWER"; pause; return 0; }
  [ "$SETUP_DONE" = 1 ] || { say warn 'Connect with opencode first, so the opencode command is set.'; pause; return 0; }
  if [ "$OC_EGRESS_DEFAULT" = ASK ]; then pick_egress || return 0; fi
  main_menu "$ANSWER"
}
home(){
  local CHECKED=0 act
  while :; do
    load_cfg; set_theme "$OCUI_THEME"; load_lang
    if [ "$CHECKED" = 0 ]; then CHECKED=1; ensure_deps; load_cfg; set_theme "$OCUI_THEME"; load_lang; [ "$UPDATE_ASK" = ask ] && check_updates auto; fi
    reset_items; SHOW_BANNER=1; HEAD=()
    local -a acts=()
    item "$(tx 'Auto opencode')" '' 'Last folder, the fastest installed route, a new IP and a fresh chat. No questions asked.'; acts+=(auto_home)
    item "$(tx 'Launch OpenCode')" '' 'Pick a folder and a connection, then start OpenCode.'; acts+=(launch)
    item "$(tx 'Status')" '' 'Which routes are installed, and the last measured time of each. Enter on a missing one installs it.'; acts+=(status_menu)
    if [ "$SETUP_DONE" = 1 ]; then
      item "$(tx 'Renew session')" '' 'Use it when the limit is hit or the login expired: backs up auth.json in the launcher state folder, clears tokens, gets a new IP.'; acts+=(renew_session)
    else
      item "$(tx 'Connect with opencode')" 'Not configured' 'Guided setup: installs what is missing, then WARP, Tor, a proxy list or direct. Creates opencode, opencodeinf and opencodeoc.' '' warn; acts+=(connect_setup)
    fi
    item "$(tx 'Settings')" '' 'View and change the launcher options. Saved at once. Support is in here too.'; acts+=(settings)
    item "$(tx 'Commands')" "$(tx "$(cmd_state)")" 'Install or remove the commands, connect with opencode, uninstall.'; acts+=(commands_menu)
    item "$(tx 'Exit')" '' 'Close the launcher.'; acts+=(quit)
    menu 'OpenCode Infinite' "$VERSION"
    [ "$MRES" -lt 0 ] && return 0
    act=${acts[MRES]}
    [ "$act" = quit ] && return 0
    "$act"
    [ "$QUIT" = 1 ] && return 0
  done
}
cleanup(){
  if [ -t 1 ]; then printf '\e[?25h\e[0m'; fi  # no escape codes into a pipe or a log
  stty sane 2>/dev/null
  lock_free  # this launcher no longer runs OpenCode, so another window may start
  # v2.60: Ctrl+C also stops the watcher started by run_session (WPID), not only the normal exit
  [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
  # stop only what this window started: its PID is the parent of the process in the pid file (a shared one stays up)
  [ -f "$STATE_DIR/tor.pid" ] && [ "$(cut -d' ' -f4 "/proc/$(cat "$STATE_DIR/tor.pid")/stat" 2>/dev/null)" = "$$" ] && tor_stop
  [ -f "$STATE_DIR/privoxy.pid" ] && [ "$(cut -d' ' -f4 "/proc/$(cat "$STATE_DIR/privoxy.pid")/stat" 2>/dev/null)" = "$$" ] && kill "$(cat "$STATE_DIR/privoxy.pid")" 2>/dev/null && rm -f "$STATE_DIR/privoxy.pid"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- entry (OCI_NO_MAIN=1 loads the functions only, for tests)
if [ -z "${OCI_NO_MAIN:-}" ]; then
  OPT_HELP=0; OPT_INSTALL=0; OPT_AUTO=0; OPT_QUIET=0; OPT_HERE=0; OPT_SAMEIP=0; NEWIP=0; RUN=0; PRESET=""; RUN_ARGS=()
  while [ $# -gt 0 ]; do
    case $1 in
      -h|--help) OPT_HELP=1;;
      --install) OPT_INSTALL=1;;
      --auto) OPT_AUTO=1;;
      --run) RUN=1; shift; RUN_ARGS+=("$@"); break;;   # the rest goes to opencode
      --preset) PRESET=${2:-}; shift;;
      --warp) PRESET=WARP; OPT_SAMEIP=1;;
      --tor) PRESET=TOR; OPT_SAMEIP=1;;
      --proxy) PRESET=PROXY; OPT_SAMEIP=1;;
      --here) OPT_HERE=1;;
      --same-ip) OPT_SAMEIP=1;;
      --new-ip) NEWIP=1;;
      --quiet) OPT_QUIET=1;;
      --) shift; RUN_ARGS+=("$@"); break;;
      -*) echo "unknown option: $1 (try --help)" >&2; exit 2;;
      *) RUN_ARGS+=("$1");;
    esac
    shift
  done
  [ "$OPT_HELP" = 1 ] && { print_help; exit 0; }
  if [ ${#RUN_ARGS[@]} -gt 0 ] && [ "$RUN" != 1 ] && [ -z "$PRESET" ]; then echo "unexpected argument: ${RUN_ARGS[0]} (try --help)" >&2; exit 2; fi
  load_cfg
  if [ "$SETUP_DONE" = 1 ]; then fix_old_shim; fi  # repairs an old shim at every start, also for the plain opencode command
  set_theme "$OCUI_THEME"
  shopt -s checkwinsize
  SEL=0; MRES=0; QUIT=0; ROUTE_READY=0
  if [ "$OPT_INSTALL" = 1 ]; then commands_install quiet; exit $?; fi
  if [ "$OPT_AUTO" = 1 ]; then auto_run; exit $?; fi
  if [ -n "$PRESET" ]; then preset_run "$PRESET" "${RUN_ARGS[@]}"; exit $?; fi
  if [ "$RUN" = 1 ]; then ensure_deps; OC_MODE_DEFAULT=CLI; if [ "$NEWIP" = 1 ]; then egress_new || { say err 'no new route.'; exit 1; }; ROUTE_READY=1; fi; run_session "$PWD" "${RUN_ARGS[@]}"; exit $?; fi  # the opencode command takes CLI arguments: always the CLI
  stty -echo -icanon 2>/dev/null
  printf '\e[?25l'
  home
fi

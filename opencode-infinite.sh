#!/usr/bin/env bash
# ==============================================================
#  OpenCode Infinite  (Ubuntu/Linux port  v1.0)
#  Multi-egress (Cloudflare WARP / Tor / free HTTP proxies / direct)
#  + dependency bootstrap + IP rotation + auto-resume.
#
#  Ported from the Windows batch launcher by Kiyoshi2006 / jeko1107.
#  Original: https://github.com/Kiyoshi2006/opencode-infinite
#
#  Usage:
#    bash opencode-infinite.sh              → main menu
#    bash opencode-infinite.sh /path/proj   → open in that folder
#    bash opencode-infinite.sh --run [args] → quick-start (saved egress)
# ==============================================================

set -euo pipefail

# ---------------------------------------------------------------
# SETTINGS  (edit freely)
# ---------------------------------------------------------------
ROTATE_TRIES_MAX=4          # rotation attempts for infra problems
IP_FIND_MAX=0               # 0 = hunt forever until a clean IP found
WARP_WAIT=6                 # seconds after (re)connecting WARP
ROTATE_COOLDOWN=10          # seconds between rotate attempts
AUTO_ROTATE=1               # 1 = auto-rotate on fatal log lines
WARP_CALL_TIMEOUT=15        # seconds a single warp-cli call may take
WATCH=1                     # 1 = watch the log, rotate on fatal error
RESUME_MSG="continue"       # message sent to resume the chat
RESUME_AUTO=1               # 1 = auto-approve tool permissions on resume
RESUME_TIMEOUT=90           # seconds the resume may run before killed
PROBE_MODEL="opencode/deepseek-v4.1-flash-free"
PROBE=1                     # 1 = probe each IP before accepting it
PROBE_BROKEN_MAX=3          # non-limit probe failures before giving up
UPDATE_CHECK=0              # 1 = check GitHub for newer launcher on start
LOG_ENABLED=1               # 1 = write to launcher.log
LOG_MAX_KB=1024             # max size of launcher.log in KB
LOG_MASK_IP=1               # 1 = mask IPs in log reports
ON_CLOSE="ask"              # "ask" / "quit" after opencode closes

# --- multi-egress tunables ---
TOR_SOCKS_PORT=9050
TOR_HTTP_PORT=8118
TOR_AUTO_INSTALL=1          # 1 = download portable Tor if not found
TOR_BOOTSTRAP_WAIT=120
PROXY_LIST_URL="https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=protocolipport&format=text"
PROXY_LIST_MIN_BYTES=20
PROXY_TRY_MAX=12
PROXY_PROBE_TIMEOUT=8
PROXY_ROT_MAX=10
PROXY_API_CHECK=0
PROXY_API_CHECK_URL="https://api.opencode.ai/"
OC_API_BASE="https://opencode.ai/update/api/latest"
UPDATE_URL="https://raw.githubusercontent.com/Kiyoshi2006/opencode-infinite/main/opencode-infinite.sh"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
NO_PROXY_LIST="localhost,127.0.0.1,0.0.0.0,::1"

# ---------------------------------------------------------------
# INTERNAL STATE
# ---------------------------------------------------------------
VERSION="1.0"
SCRIPT_PATH="$(realpath "$0")"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode-infinite"
LASTFOLDER="$STATE_DIR/lastfolder.txt"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
LOGFILE="$DATA_DIR/log/opencode.log"
TOR_DIR="$STATE_DIR/tor"
LAUNCHER_LOG="$STATE_DIR/launcher.log"
LOCK_FILE="$STATE_DIR/lock"

EGRESS="WARP"
ACTIVE_PROXY=""
WARP_UP=0
WARP_BIN=""
OC_CMD=""
OC_VER=""
CAP_STANDALONE=""
CAP_SERVICE=""
QHIT=""
FHIT=""
IP=""
WARP_FLAG=""
RESUME=""
COLD=0
OURTOR=""
OURBRIDGE=""
OPFOLDER=""
APP_MODE="CLI"

# fatal-line pattern (grep -E)
OC_PAT='level=ERROR.*(Failed to drain Session|free usage limit|usage limit reached|rate limit|out of usage|insufficient credits|payment required)'

# ---------------------------------------------------------------
# COLOUR
# ---------------------------------------------------------------
if [ -t 1 ]; then
    C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"
    C_BOLD="\033[1m"; C_RST="\033[0m"; C_CYAN="\033[36m"
else
    C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""; C_RST=""; C_CYAN=""
fi

# ---------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------
log() {
    local msg="$1" tag="${2:-info}"
    [ "$LOG_ENABLED" = "1" ] || return 0
    local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"
    echo "[$ts] [$tag] $msg" >> "$LAUNCHER_LOG" 2>/dev/null || true
}

# Đọc stdin và ghi từng dòng vào log (dùng để pipe output warp-cli vào log)
log_pipe() {
    local tag="${1:-info}"
    while IFS= read -r line; do
        [ -n "$line" ] && log "$line" "$tag"
    done
}

trim_log() {
    local f="$1" max_kb="${2:-1024}"
    [ -f "$f" ] || return
    local max_b=$(( max_kb * 1024 ))
    local sz; sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
    if [ "$sz" -gt "$max_b" ]; then
        local keep=$(( max_b / 2 ))
        tail -c "$keep" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
}

# ---------------------------------------------------------------
# LOCK
# ---------------------------------------------------------------
lock_check() {
    mkdir -p "$STATE_DIR"
    if [ -f "$LOCK_FILE" ]; then
        local pid; pid="$(cat "$LOCK_FILE" 2>/dev/null || echo 0)"
        # PID còn sống VÀ đúng là process opencode-infinite (không phải PID tái sử dụng)
        if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
            local cmdline; cmdline="$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' || echo '')"
            if echo "$cmdline" | grep -q "opencode-infinite"; then
                echo -e "${C_WARN}[!] Another instance is already running (PID $pid).${C_RST}"
                echo "    Close it or delete $LOCK_FILE to continue."
                exit 1
            fi
        fi
        # Stale lock (process đã chết hoặc PID bị tái sử dụng) — xóa và tiếp tục
        rm -f "$LOCK_FILE"
    fi
    echo "$$" > "$LOCK_FILE"
}

lock_release() {
    rm -f "$LOCK_FILE"
}

# ---------------------------------------------------------------
# CLEANUP / QUIT
# ---------------------------------------------------------------
cleanup() {
    log "exit" boot
    lock_release
    # stop Tor/bridge we started
    if [ -n "$OURTOR" ] && kill -0 "$OURTOR" 2>/dev/null; then
        kill "$OURTOR" 2>/dev/null || true
    fi
    if [ -n "$OURBRIDGE" ] && kill -0 "$OURBRIDGE" 2>/dev/null; then
        kill "$OURBRIDGE" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------
# DEPENDENCY HELPERS
# ---------------------------------------------------------------
have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_cmd() {
    if ! have_cmd "$1"; then
        echo -e "${C_ERR}  ERROR: '$1' not found. Install it and retry.${C_RST}"
        return 1
    fi
}

# Install a package (apt-get)
apt_install() {
    echo "    Installing $1 ..."
    if have_cmd sudo; then
        sudo apt-get install -y "$1" >/dev/null 2>&1
    else
        apt-get install -y "$1" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------
# WARP
# ---------------------------------------------------------------
find_warp() {
    WARP_BIN=""
    if have_cmd warp-cli; then
        WARP_BIN="$(command -v warp-cli)"
    fi
}

install_warp() {
    echo "    Downloading Cloudflare WARP for Linux..."
    # Official Cloudflare Linux WARP install script
    if have_cmd curl; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
            sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | \
            sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null 2>&1
        sudo apt-get update -qq && sudo apt-get install -y cloudflare-warp >/dev/null 2>&1
    fi
}

# Kiểm tra WARP đang ở tunnel mode khi đã connected (nguy hiểm trên VPS)
# KHÔNG disconnect nếu tunnel mode — SSH đang đi qua WARP, disconnect = mất SSH
warp_check_tunnel_danger() {
    [ -z "$WARP_BIN" ] && return 0
    local status settings
    status="$("$WARP_BIN" status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/\r//' || echo "")"
    if echo "$status" | grep -qi 'Connected'; then
        settings="$("$WARP_BIN" settings 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/\r//' || echo "")"
        if echo "$settings" | grep -qi 'Tunnel' && ! echo "$settings" | grep -qi 'proxy'; then
            echo ""
            echo -e "${C_ERR}  [!] WARP đang CONNECTED ở TUNNEL MODE!${C_RST}"
            echo -e "${C_ERR}      Script KHÔNG thể tự fix — disconnect từ SSH sẽ mất SSH luôn.${C_RST}"
            echo ""
            echo "      Fix từ serial console (Oracle Cloud Console):"
            echo "        warp-cli disconnect"
            echo "        warp-cli mode proxy"
            echo ""
            echo "      Sau đó chạy lại script và làm theo hướng dẫn setup WARP."
            log "warp tunnel mode detected — aborted, user must fix via serial console" warp
            return 1
        fi
    fi
    return 0
}

# Kiểm tra WARP đã đăng ký chưa (account tồn tại)
warp_is_registered() {
    local status
    status="$("$WARP_BIN" status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/\r//')"
    # Nếu output chứa "Registration Missing" hoặc không có "Account" → chưa đăng ký
    echo "$status" | grep -qiE 'Registration Missing|Not Registered' && return 1
    echo "$status" | grep -qiE 'Account|Connected|Connecting|Disconnected' && return 0
    return 1
}

# Helper: chạy warp-cli, auto-accept ToS (pipe y vào stdin), redirect output vào log
warp_cmd() {
    # Chạy warp-cli, redirect stdout/stderr vào log (không ra terminal)
    # printf 'y\n' chỉ cần cho 'registration new' (ToS prompt đọc stdin)
    local out
    out="$(printf 'y\n' | timeout "$WARP_CALL_TIMEOUT" "$WARP_BIN" "$@" \
        2>&1 | sed 's/\x1b\[[0-9;]*m//g; s/\r//' || true)"
    [ -n "$out" ] && log "warp_cmd $*: $out" warp
}

# Kết nối WARP proxy mode (chỉ gọi khi đã qua warp_check_tunnel_danger)
warp_up() {
    PROXY_PORT=40000
    ACTIVE_PROXY=""

    # Đăng ký nếu chưa có account
    if ! warp_is_registered; then
        echo "    WARP chưa đăng ký — đang tạo account..."
        warp_cmd --accept-tos registration new
        sleep 2
        if ! warp_is_registered; then
            echo -e "${C_ERR}  [!] WARP registration thất bại.${C_RST}"
            log "warp reg failed" warp; return 1
        fi
    fi

    local status
    status="$("$WARP_BIN" status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/\r//' || echo "")"

    if echo "$status" | grep -qi 'Connected'; then
        # Đã connected (proxy mode đã verify bởi warp_check_tunnel_danger)
        echo "    WARP đã connected."
    else
        # Chưa connected → set proxy mode rồi connect
        echo "    Thiết lập proxy mode..."
        "$WARP_BIN" mode proxy 2>/dev/null || true
        sleep 1
        "$WARP_BIN" proxy port "$PROXY_PORT" 2>/dev/null || true
        sleep 1
        echo "    Connecting WARP..."
        warp_cmd connect
        sleep "$WARP_WAIT"

        # Verify KHÔNG bị tunnel mode sau khi connect
        local post_settings
        post_settings="$("$WARP_BIN" settings 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/\r//' || echo "")"
        if echo "$post_settings" | grep -qi 'Tunnel' && ! echo "$post_settings" | grep -qi 'proxy'; then
            echo -e "${C_ERR}  [!] WARP connected nhưng vẫn tunnel mode — DISCONNECT ngay!${C_RST}"
            "$WARP_BIN" disconnect 2>/dev/null || true
            log "warp post-connect tunnel mode: force disconnected" warp; return 1
        fi
    fi

    # Verify proxy port listening
    if ! nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null; then
        echo -e "${C_WARN}  [!] WARP proxy port $PROXY_PORT không listen — falling back NONE.${C_RST}"
        ACTIVE_PROXY=""; log "warp proxy port not listening" warp; return 1
    fi

    # WARP proxy mode là SOCKS5. Kiểm tra thật: traffic qua proxy có ra Cloudflare (warp=on) không
    local t
    t="$(curl -s --max-time 10 --proxy "http://127.0.0.1:$PROXY_PORT" "$TRACE_URL" 2>/dev/null || true)"
    if echo "$t" | grep -qE '^warp=(on|plus)'; then
        ACTIVE_PROXY="http://127.0.0.1:$PROXY_PORT"
    else
        t="$(curl -s --max-time 10 --proxy "socks5h://127.0.0.1:$PROXY_PORT" "$TRACE_URL" 2>/dev/null || true)"
        if echo "$t" | grep -qE '^warp=(on|plus)'; then
            WARP_HTTP_PORT=40001
            start_http_bridge "$WARP_HTTP_PORT" "$PROXY_PORT" || { ACTIVE_PROXY=""; return 1; }
            ACTIVE_PROXY="http://127.0.0.1:$WARP_HTTP_PORT"
        else
            echo -e "${C_ERR}  [!] Traffic qua WARP proxy KHÔNG ra Cloudflare (warp!=on) — không dùng WARP.${C_RST}"
            log "warp trace failed: $t" warp
            ACTIVE_PROXY=""; return 1
        fi
    fi
    echo -e "${C_OK}  WARP proxy up → $ACTIVE_PROXY${C_RST}"
    log "warp proxy up on $ACTIVE_PROXY" warp
}

warp_rotate() {
    log "warp_rotate: start" warp
    warp_cmd disconnect
    warp_cmd registration delete
    sleep 2
    warp_cmd --accept-tos registration new
    log "warp rotate: registration done" warp
    sleep "$ROTATE_COOLDOWN"
    # PHẢI set proxy mode trước khi connect (tránh tunnel mode → mất SSH)
    warp_cmd mode proxy
    warp_cmd proxy port 40000
    warp_cmd connect
    sleep "$WARP_WAIT"
    log "warp rotated" warp
}

# ---------------------------------------------------------------
# TOR
# ---------------------------------------------------------------
find_tor() {
    if have_cmd tor; then
        echo "$(command -v tor)"
        return 0
    fi
    if [ -x "$TOR_DIR/tor/tor" ]; then
        echo "$TOR_DIR/tor/tor"
        return 0
    fi
    return 1
}

install_tor_portable() {
    echo "    Installing Tor (apt)..."
    apt_install tor || true
    if ! have_cmd tor; then
        echo -e "${C_WARN}  [!] Could not install Tor via apt.${C_RST}"
        return 1
    fi
}

# ---------------------------------------------------------------
# HTTP(CONNECT) -> SOCKS5 bridge (python3). OpenCode (Bun) chỉ hiểu HTTP proxy,
# trong khi WARP proxy mode / Tor chỉ nói SOCKS5.
# ---------------------------------------------------------------
start_http_bridge() {
    local http_port="$1" socks_port="$2"
    if nc -z 127.0.0.1 "$http_port" 2>/dev/null; then
        echo "    [bridge] port $http_port đã có — dùng lại"
        return 0
    fi
    if ! have_cmd python3; then
        echo -e "${C_WARN}  [!] Cần python3 cho HTTP bridge: sudo apt install -y python3${C_RST}"
        return 1
    fi
    mkdir -p "$STATE_DIR"
    local bf="$STATE_DIR/http2socks.py"
    cat > "$bf" <<'PYEOF'
import sys, socket, threading, struct, select

http_port = int(sys.argv[1])
socks_port = int(sys.argv[2])

def socks5_connect(host, port):
    s = socket.create_connection(('127.0.0.1', socks_port), timeout=15)
    s.sendall(b'\x05\x01\x00')
    if s.recv(2) != b'\x05\x00':
        raise IOError('SOCKS5 handshake failed')
    hb = host.encode()
    s.sendall(b'\x05\x01\x00\x03' + bytes([len(hb)]) + hb + struct.pack('>H', port))
    resp = s.recv(10)
    if len(resp) < 2 or resp[1] != 0:
        raise IOError('SOCKS5 connect failed')
    s.settimeout(None)
    return s

def pipe(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 120)
            if not r:
                break
            for s in r:
                d = s.recv(65536)
                if not d:
                    return
                (b if s is a else a).sendall(d)
    except Exception:
        pass

def handle(client):
    remote = None
    try:
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = client.recv(65536)
            if not chunk:
                return
            data += chunk
        head, _, rest = data.partition(b'\r\n\r\n')
        line = head.split(b'\r\n')[0].decode('latin1')
        method, target = line.split()[0], line.split()[1]
        if method == 'CONNECT':
            host, port = target.rsplit(':', 1)
            remote = socks5_connect(host, int(port))
            client.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            if rest:
                remote.sendall(rest)
        else:
            # plain HTTP proxy request: http://host[:port]/path
            u = target.split('://', 1)[-1]
            hostport, _, path = u.partition('/')
            host, _, port = hostport.partition(':')
            remote = socks5_connect(host, int(port or 80))
            lines = head.split(b'\r\n')
            lines[0] = (method + ' /' + path + ' ' + line.split()[2]).encode('latin1')
            remote.sendall(b'\r\n'.join(lines) + b'\r\n\r\n' + rest)
        pipe(client, remote)
    except Exception:
        pass
    finally:
        for x in (remote, client):
            try:
                if x: x.close()
            except Exception:
                pass

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', http_port))
srv.listen(128)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PYEOF
    python3 "$bf" "$http_port" "$socks_port" >/dev/null 2>&1 &
    OURBRIDGE=$!
    disown "$OURBRIDGE" 2>/dev/null || true
    log "http bridge pid=$OURBRIDGE http=$http_port socks=$socks_port" bridge
    sleep 1
    if ! nc -z 127.0.0.1 "$http_port" 2>/dev/null; then
        echo -e "${C_ERR}  [!] HTTP bridge không khởi động được (port $http_port).${C_RST}"
        return 1
    fi
    echo "    [bridge] HTTP:$http_port → SOCKS5:$socks_port"
    return 0
}

tor_setup() {
    local tor_bin; tor_bin="$(find_tor 2>/dev/null || echo "")"
    if [ -z "$tor_bin" ]; then
        if [ "$TOR_AUTO_INSTALL" = "1" ]; then
            install_tor_portable
            tor_bin="$(find_tor 2>/dev/null || echo "")"
        fi
    fi
    if [ -z "$tor_bin" ]; then
        echo -e "${C_ERR}  [!] Tor not found and could not be installed.${C_RST}"
        return 1
    fi

    # check if tor is already running on SOCKS port
    if nc -z 127.0.0.1 "$TOR_SOCKS_PORT" 2>/dev/null; then
        echo "    [tor] already running on port $TOR_SOCKS_PORT"
    else
        echo "    [tor] starting..."
        mkdir -p "$STATE_DIR/tor-data"
        "$tor_bin" \
            --SocksPort "$TOR_SOCKS_PORT" \
            --DataDirectory "$STATE_DIR/tor-data" \
            --ControlPort 9051 \
            --Log "warn stdout" \
            --quiet &
        OURTOR=$!
        log "tor started pid=$OURTOR" tor

        echo -n "    Waiting for Tor bootstrap (up to ${TOR_BOOTSTRAP_WAIT}s)..."
        local waited=0
        while [ "$waited" -lt "$TOR_BOOTSTRAP_WAIT" ]; do
            if nc -z 127.0.0.1 "$TOR_SOCKS_PORT" 2>/dev/null; then
                echo " ready."
                break
            fi
            sleep 2; waited=$(( waited + 2 ))
            echo -n "."
        done
        if ! nc -z 127.0.0.1 "$TOR_SOCKS_PORT" 2>/dev/null; then
            echo -e "\n${C_ERR}  [!] Tor did not bootstrap in time.${C_RST}"
            return 1
        fi
    fi

    start_http_bridge "$TOR_HTTP_PORT" "$TOR_SOCKS_PORT" || return 1
    sleep 1
    ACTIVE_PROXY="http://127.0.0.1:$TOR_HTTP_PORT"
    return 0
}

tor_new_circuit() {
    # Signal Tor for a new circuit via control port
    if have_cmd nc; then
        printf 'AUTHENTICATE ""\r\nSIGNAL NEWNYM\r\nQUIT\r\n' | \
            nc -q1 127.0.0.1 9051 >/dev/null 2>&1 || true
    fi
    sleep 3
    log "tor new circuit" tor
}

# ---------------------------------------------------------------
# FREE HTTP PROXY
# ---------------------------------------------------------------
PROXY_LIST=()
PROXY_TRIED=()
PROXY_BURNED=()

load_proxy_list() {
    echo "    Downloading proxy list..."
    local raw
    if [ -f "$PROXY_LIST_URL" ]; then
        raw="$(cat "$PROXY_LIST_URL")"
    else
        raw="$(curl -fsSL --max-time 15 "$PROXY_LIST_URL" 2>/dev/null || echo "")"
    fi
    if [ ${#raw} -lt "$PROXY_LIST_MIN_BYTES" ]; then
        echo -e "${C_WARN}  [!] Proxy list too short or download failed.${C_RST}"
        return 1
    fi
    # Extract ip:port or http://ip:port entries
    PROXY_LIST=()
    while IFS= read -r line; do
        line="${line//[$'\r\n']/}"
        # skip comments / socks
        [[ "$line" =~ ^['#'';'] ]] && continue
        [[ "$line" =~ ^socks ]] && continue
        if [[ "$line" =~ ^http ]] || [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+ ]]; then
            PROXY_LIST+=("$line")
        fi
    done <<< "$raw"
    echo "    [proxy] ${#PROXY_LIST[@]} proxies loaded."
    log "proxy list loaded count=${#PROXY_LIST[@]}" proxy
}

is_burned() {
    local p="$1"
    for b in "${PROXY_BURNED[@]:-}"; do
        [ "$b" = "$p" ] && return 0
    done
    return 1
}

pick_free_proxy() {
    ACTIVE_PROXY=""
    local tried=0
    for p in "${PROXY_LIST[@]:-}"; do
        is_burned "$p" && continue
        [ "$tried" -ge "$PROXY_TRY_MAX" ] && break
        tried=$(( tried + 1 ))
        # Quick connectivity check
        local host port
        p_clean="${p#http://}"; p_clean="${p_clean#https://}"
        host="${p_clean%%:*}"; port="${p_clean##*:}"
        if timeout "$PROXY_PROBE_TIMEOUT" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            ACTIVE_PROXY="http://$p_clean"
            log "proxy selected $ACTIVE_PROXY" proxy
            return 0
        fi
        PROXY_BURNED+=("$p")
    done
    echo -e "${C_WARN}  [!] No working free proxy found.${C_RST}"
    return 1
}

# ---------------------------------------------------------------
# IP CHECK
# ---------------------------------------------------------------
get_ip() {
    local proxy="${1:-}"
    local opts=""
    [ -n "$proxy" ] && opts="--proxy $proxy"
    local out
    out="$(curl -fsSL --max-time 8 $opts "$TRACE_URL" 2>/dev/null || echo "")"
    IP=""
    WARP_FLAG=""
    while IFS='=' read -r k v; do
        [ "$k" = "ip" ] && IP="$v"
        [ "$k" = "warp" ] && WARP_FLAG="$v"
    done <<< "$out"
}

# ---------------------------------------------------------------
# OPENCODE
# ---------------------------------------------------------------
find_opencode() {
    OC_CMD=""
    OC_VER=""
    local candidates=()
    # Common install locations
    have_cmd opencode && candidates+=("$(command -v opencode)")
    [ -x "$HOME/.opencode/bin/opencode" ] && candidates+=("$HOME/.opencode/bin/opencode")
    [ -x "$HOME/.local/bin/opencode"    ] && candidates+=("$HOME/.local/bin/opencode")
    # npm global bin
    local npm_bin
    npm_bin="$(npm bin -g 2>/dev/null || echo "")"
    [ -n "$npm_bin" ] && [ -x "$npm_bin/opencode" ] && candidates+=("$npm_bin/opencode")
    # pick first working candidate
    for c in "${candidates[@]:-}"; do
        local raw; raw="$("$c" --version 2>/dev/null | tr -d '[:space:]' || echo "")"
        if [ -n "$raw" ]; then
            OC_CMD="$c"
            # Strip prefix như "opencodev" → chỉ giữ "2.2.5"
            OC_VER="$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
            [ -z "$OC_VER" ] && OC_VER="$raw"
            break
        fi
    done
}

install_opencode() {
    echo "    Installing opencode via npm..."
    if ! have_cmd npm; then
        echo "    npm not found, installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - >/dev/null 2>&1
        sudo apt-get install -y nodejs >/dev/null 2>&1
    fi
    npm install -g @opencode/cli 2>&1 | tail -3
}

detect_caps() {
    CAP_STANDALONE=""
    CAP_SERVICE=""
    [ -z "$OC_CMD" ] && return
    if "$OC_CMD" run --help 2>&1 | grep -q 'standalone'; then
        CAP_STANDALONE=1
    fi
    if "$OC_CMD" service --help 2>/dev/null | grep -q 'service\|start'; then
        CAP_SERVICE=1
    fi
    log "caps standalone=$CAP_STANDALONE service=$CAP_SERVICE" deps
}

oc_update_check() {
    [ -z "$OC_CMD" ] && return
    [ -z "$OC_VER" ] && return
    local latest
    latest="$(curl -fsSL --max-time 8 "$OC_API_BASE" 2>/dev/null | \
        grep -oE '"version"\s*:\s*"[^"]+"' | head -1 | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
    [ -z "$latest" ] && return
    if [ "$latest" != "$OC_VER" ]; then
        echo -e "${C_CYAN}  [upd] Newer opencode available: $latest (current: $OC_VER)${C_RST}"
        echo -n "        Update now? [Y/n]: "
        read -r ans
        if [[ "$ans" =~ ^[Yy]$|^$ ]]; then
            if ! have_cmd npm; then
                echo "  npm chưa có — đang cài Node.js (nodesource LTS)..."
                curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - >/dev/null 2>&1
                sudo apt-get install -y nodejs >/dev/null 2>&1
            fi
            if have_cmd npm; then
                npm install -g @opencode/cli 2>&1 | tail -3
                find_opencode
            else
                echo -e "${C_ERR}  [!] Không cài được npm, bỏ qua update.${C_RST}"
            fi
        fi
    fi
}

# ---------------------------------------------------------------
# SELF-UPDATE
# ---------------------------------------------------------------
self_update() {
    [ "$UPDATE_CHECK" = "1" ] || return 0
    local remote
    remote="$(curl -fsSL --max-time 10 "$UPDATE_URL" 2>/dev/null || echo "")"
    [ -z "$remote" ] && return 0
    local rver; rver="$(echo "$remote" | grep -m1 'VERSION=' | grep -oE '[0-9]+\.[0-9]+')"
    [ -z "$rver" ] && return 0
    if [[ "$rver" > "$VERSION" ]]; then
        echo -e "${C_CYAN}  [upd] Newer launcher available: v$rver (current: v$VERSION)${C_RST}"
        echo -n "        Replace this script? [Y/n]: "
        read -r ans
        [[ "$ans" =~ ^[Nn]$ ]] && return 0
        local backup="${SCRIPT_PATH}.bak"
        cp "$SCRIPT_PATH" "$backup"
        echo "$remote" > "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo "    Backup saved to $backup. Restarting..."
        exec bash "$SCRIPT_PATH" "$@"
    fi
}

# ---------------------------------------------------------------
# HELPER: chạy lệnh với proxy nếu có, không dùng env array rỗng
# ---------------------------------------------------------------
run_cmd_proxy() {
    # run_cmd_proxy <proxy_url> <cmd> [args...]
    local proxy="$1"; shift
    if [ -n "$proxy" ]; then
        HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" \
        http_proxy="$proxy" https_proxy="$proxy" \
        NO_PROXY="$NO_PROXY_LIST" no_proxy="$NO_PROXY_LIST" \
        "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------
# PROBE  (cheap message to test an IP)
# ---------------------------------------------------------------
probe_ip() {
    [ "$PROBE" = "1" ] || return 0
    local proxy="${1:-}"
    echo "    Probing IP..."
    local env_args=()
    if [ -n "$proxy" ]; then
        env_args+=("HTTP_PROXY=$proxy" "HTTPS_PROXY=$proxy" "NO_PROXY=$NO_PROXY_LIST")
    fi
    local probe_id="ses_probe0000000"
    local out
    out="$(run_cmd_proxy "$proxy" timeout 30 \
        "$OC_CMD" run --session "$probe_id" \
        ${CAP_STANDALONE:+--standalone} \
        --model "$PROBE_MODEL" \
        "ping" 2>&1 || echo "PROBEFAIL")"

    # delete probe session
    run_cmd_proxy "$proxy" "$OC_CMD" session delete "$probe_id" >/dev/null 2>&1 || true

    if echo "$out" | grep -qiE 'limit|quota|credits|rate.?limit|payment'; then
        log "probe: IP burned (limit response)" probe
        return 1   # burned
    fi
    if echo "$out" | grep -q "PROBEFAIL"; then
        log "probe: generic failure" probe
        return 2   # generic failure
    fi
    log "probe: OK" probe
    return 0
}

# ---------------------------------------------------------------
# LOG WATCHER
# ---------------------------------------------------------------
watch_pid=""

watch_start() {
    [ "$WATCH" = "1" ] || return 0
    [ -z "$LOGFILE" ] && return 0
    QHIT=""; FHIT=""
    # tail the opencode log and signal ourselves when a fatal line appears
    # -n 0 = chỉ đọc log MỚI, bỏ qua nội dung cũ từ session trước
    (
        tail -F -n 0 "$LOGFILE" 2>/dev/null | \
        grep -m1 --line-buffered -E "$OC_PAT" >/dev/null 2>&1
        # Send SIGUSR1 to the parent launcher
        kill -USR1 $$ 2>/dev/null || true
    ) &
    watch_pid=$!
    # On fatal log line, set FHIT
    trap 'FHIT=1' USR1
    log "watcher started pid=$watch_pid" watch
}

watch_stop() {
    trap - USR1
    if [ -n "$watch_pid" ] && kill -0 "$watch_pid" 2>/dev/null; then
        kill "$watch_pid" 2>/dev/null || true
    fi
    watch_pid=""
}

scan_log() {
    # Chỉ đọc log được ghi SAU khi OpenCode lần này bắt đầu chạy
    [ -f "$LOGFILE" ] || return 1
    local since="${LOG_RUN_TS:-0}"
    # Lọc theo file modification time: chỉ xét nếu log được sửa gần đây
    local log_mt; log_mt="$(stat -c %Y "$LOGFILE" 2>/dev/null || echo 0)"
    [ "$log_mt" -lt "$since" ] && return 1
    if tail -200 "$LOGFILE" 2>/dev/null | grep -qE "$OC_PAT"; then
        QHIT=1; return 0
    fi
    return 1
}

# ---------------------------------------------------------------
# ROTATE EGRESS
# ---------------------------------------------------------------
rotate() {
    local attempt="${1:-1}"
    echo ""
    echo -e "${C_WARN}  [rotate] attempt $attempt ...${C_RST}"
    log "rotate attempt=$attempt egress=$EGRESS" rotate

    case "$EGRESS" in
    WARP)
        if [ -z "$WARP_BIN" ]; then
            echo -e "${C_WARN}  [!] WARP not available — cannot rotate.${C_RST}"
            return 1
        fi
        warp_rotate
        sleep "$ROTATE_COOLDOWN"
        get_ip "$ACTIVE_PROXY"
        echo "    New IP: ${IP:-unknown}"
        ;;
    TOR)
        tor_new_circuit
        get_ip "$ACTIVE_PROXY"
        echo "    New circuit IP: ${IP:-unknown}"
        ;;
    PROXY)
        pick_free_proxy || return 1
        get_ip "$ACTIVE_PROXY"
        echo "    New proxy IP: ${IP:-unknown}"
        ;;
    NONE)
        echo "    NONE egress — no rotation possible."
        return 1
        ;;
    esac
    return 0
}

# ---------------------------------------------------------------
# RESUME CHAT
# ---------------------------------------------------------------
resume_chat() {
    log "resume start" resume
    echo -e "${C_CYAN}  [resume] Sending: $RESUME_MSG${C_RST}"
    local rc=0
    run_cmd_proxy "$ACTIVE_PROXY" timeout "$RESUME_TIMEOUT" \
        "$OC_CMD" run \
        ${CAP_STANDALONE:+--standalone} \
        ${RESUME_AUTO:+--auto-approve} \
        --continue \
        "$RESUME_MSG" 2>&1 | tail -5 || rc=$?
    if [ "$rc" -eq 124 ]; then
        echo -e "${C_WARN}  [resume] timed out — will rotate.${C_RST}"
        return 1
    fi
    log "resume done rc=$rc" resume
    return 0
}

# ---------------------------------------------------------------
# RUN OPENCODE
# ---------------------------------------------------------------
run_opencode() {
    local runargs="${1:-}"
    QHIT=""; FHIT=""

    watch_start

    echo ""
    echo -e "${C_BOLD}  Launching OpenCode...${C_RST}"
    echo "  Folder : $OPFOLDER"
    echo "  Egress : $EGRESS${ACTIVE_PROXY:+  Proxy: $ACTIVE_PROXY}"
    echo ""

    # Ghi timestamp trước khi chạy → scan_log chỉ đọc log SAU điểm này
    LOG_RUN_TS="$(date '+%s')"

    local rc=0
    # shellcheck disable=SC2086
    (cd "$OPFOLDER" && \
     run_cmd_proxy "$ACTIVE_PROXY" "$OC_CMD" \
         ${RESUME:+--continue} \
         $runargs) || rc=$?

    watch_stop
    log "opencode exited rc=$rc fhit=$FHIT qhit=$QHIT" run
    return $rc
}

# ---------------------------------------------------------------
# AUTO-ROTATE LOOP
# ---------------------------------------------------------------
auto_rotate_loop() {
    local runargs="${1:-}"
    local tries=0

    # Kết nối egress lần đầu (nếu chưa kết nối)
    if [ "$WARP_UP" = "0" ] || [ -z "$ACTIVE_PROXY" -a "$EGRESS" != "NONE" ]; then
        egress_connect || { echo -e "${C_ERR}  Could not connect egress.${C_RST}"
            echo -n "  Press Enter to return to menu..."; read -r; return 1; }
        WARP_UP=1
    fi

    while true; do
        run_opencode "$runargs"
        local rc=$?

        # check if a fatal/quota line was seen
        scan_log
        local fatal="${FHIT:-}${QHIT:-}"

        if [ -z "$fatal" ]; then
            [ "$rc" -ne 0 ] && echo -e "${C_WARN}  (OpenCode thoát rc=$rc, không thấy lỗi limit trong log — không rotate)${C_RST}"
            # clean exit — hỏi user muốn làm gì
            echo ""
            echo -e "${C_OK}  OpenCode đã thoát.${C_RST}"
            case "$ON_CLOSE" in
            quit) break ;;
            *)
                echo "  [r] Mở lại  [m] Về menu  [q] Thoát"
                echo -n "  Pick: "; read -r oc_ans
                case "$oc_ans" in
                r|R) continue ;;
                q|Q) exit 0 ;;
                *) break ;;
                esac
                ;;
            esac
            break
        fi

        if [ "$AUTO_ROTATE" != "1" ]; then
            echo -e "${C_WARN}  [!] OpenCode exited (rc=$rc). Auto-rotate is off.${C_RST}"
            echo -n "  Press Enter..."; read -r
            break
        fi

        tries=$(( tries + 1 ))
        if [ "$ROTATE_TRIES_MAX" -gt 0 ] && [ "$tries" -gt "$ROTATE_TRIES_MAX" ]; then
            echo -e "${C_ERR}  [!] Max rotation tries ($ROTATE_TRIES_MAX) reached.${C_RST}"
            break
        fi

        echo -e "${C_WARN}  [!] Fatal/quota hit — rotating egress (try $tries)...${C_RST}"

        if ! rotate "$tries"; then
            echo -e "${C_ERR}  [!] Rotation failed.${C_RST}"
            break
        fi

        # optionally probe new IP
        if [ "$PROBE" = "1" ] && [ "$EGRESS" != "NONE" ]; then
            local probe_ok=false
            local burned=0
            local find_tries=0
            while true; do
                local pr; probe_ip "$ACTIVE_PROXY"; pr=$?
                if [ "$pr" -eq 0 ]; then
                    probe_ok=true; break
                elif [ "$pr" -eq 1 ]; then
                    burned=$(( burned + 1 ))
                    echo -e "${C_WARN}  IP burned — rotating again...${C_RST}"
                    rotate "extra"
                elif [ "$pr" -eq 2 ]; then
                    # non-limit failure
                    PROBE_BROKEN_MAX=$(( PROBE_BROKEN_MAX - 1 ))
                    [ "$PROBE_BROKEN_MAX" -le 0 ] && { echo -e "${C_WARN}  Probe broken — skipping.${C_RST}"; probe_ok=true; break; }
                fi
                find_tries=$(( find_tries + 1 ))
                [ "$IP_FIND_MAX" -gt 0 ] && [ "$find_tries" -ge "$IP_FIND_MAX" ] && { echo -e "${C_WARN}  IP find limit reached.${C_RST}"; break; }
            done
        fi

        # resume the chat on new egress
        RESUME=1
        resume_chat || true

    done
}

# ---------------------------------------------------------------
# EGRESS CONNECT
# ---------------------------------------------------------------
egress_connect() {
    case "$EGRESS" in
    WARP)
        if [ -z "$WARP_BIN" ]; then
            echo -e "${C_WARN}  [!] WARP not found — switching to NONE.${C_RST}"
            EGRESS=NONE; ACTIVE_PROXY=""; return 0
        fi
        warp_check_tunnel_danger || return 1
        warp_up
        get_ip "$ACTIVE_PROXY"
        echo "  IP: ${IP:-unknown}  WARP: ${WARP_FLAG:-?}"
        ;;
    TOR)
        tor_setup || return 1
        get_ip "$ACTIVE_PROXY"
        echo "  IP (via Tor): ${IP:-unknown}"
        ;;
    PROXY)
        load_proxy_list || return 1
        pick_free_proxy || return 1
        get_ip "$ACTIVE_PROXY"
        echo "  IP (via proxy): ${IP:-unknown}"
        ;;
    NONE)
        ACTIVE_PROXY=""
        get_ip ""
        echo "  IP (direct): ${IP:-unknown}"
        ;;
    esac
    return 0
}

# ---------------------------------------------------------------
# DEEP RESET
# ---------------------------------------------------------------
deep_reset() {
    echo ""
    echo -e "${C_WARN}  [!] Deep reset: chat history will be archived to ~/Desktop.${C_RST}"
    echo -n "    Continue? [y/N]: "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || return
    pkill -f opencode 2>/dev/null || true
    local dest
    dest=~/Desktop/opencode-backup-"$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dest"
    cp -r "$DATA_DIR" "$dest/" 2>/dev/null || true
    rm -rf "$DATA_DIR" 2>/dev/null || true
    echo "    Archived to $dest"
    log "deep reset archived to $dest" reset
}

token_reset() {
    pkill -f "opencode.*service\|opencode.*server" 2>/dev/null || true
    # Remove auth/token files but keep chats
    find "$DATA_DIR" \( -name "*.token" -o -name "auth.json" -o -name "credentials*" \) \
        -exec rm -f {} + 2>/dev/null || true
    echo "  Tokens cleared. Chats untouched."
    log "token reset" reset
}

# ---------------------------------------------------------------
# MAIN MENU
# ---------------------------------------------------------------
show_menu() {
    clear
    echo "============================================================"
    echo -e "${C_BOLD}  OpenCode Infinite  v$VERSION  [Ubuntu]${C_RST}"
    echo ""
    echo "  Folder : $OPFOLDER"
    echo "  Egress : $EGRESS"
    [ -n "$ACTIVE_PROXY" ] && echo "  Proxy  : $ACTIVE_PROXY"
    [ -n "$IP"           ] && echo "  IP     : $IP"
    [ -n "$OC_VER"       ] && echo "  OC ver : $OC_VER"
    echo "============================================================"
    echo ""
    echo "  [1] Fresh start    - new IP/proxy, open OpenCode"
    echo "  [2] Continue       - same egress, resume last chat"
    echo "  [3] Change IP      - rotate / new proxy only"
    echo "  [4] Change folder  - work in a different folder"
    echo "  [5] Deep reset     - archive chats, clear tokens, fresh session"
    echo "  [7] Token reset    - clear tokens, keep chats"
    echo "  [8] Settings       - change egress"
    echo "  [q] Quit"
    echo ""
    echo -n "  Pick: "
}

settings_menu() {
    clear
    echo "  Current egress: $EGRESS"
    echo ""
    echo "  [1] WARP    - Cloudflare WARP proxy (rotation supported)"
    echo "  [2] TOR     - portable Tor + built-in HTTP bridge"
    echo "  [3] PROXY   - free HTTP proxies (ProxyScrape)"
    echo "  [4] NONE    - direct, no proxy"
    echo "  [b] Back"
    echo ""
    echo -n "  Pick egress: "
    read -r pick
    case "$pick" in
    1) EGRESS=WARP;  ACTIVE_PROXY="" ;;
    2) EGRESS=TOR;   ACTIVE_PROXY="http://127.0.0.1:$TOR_HTTP_PORT" ;;
    3) EGRESS=PROXY; ACTIVE_PROXY="" ;;
    4) EGRESS=NONE;  ACTIVE_PROXY="" ;;
    esac
    log "egress changed to $EGRESS" settings
}

folder_menu() {
    echo ""
    local last=""
    [ -f "$LASTFOLDER" ] && last="$(cat "$LASTFOLDER" 2>/dev/null | tr -d '"')"
    [ -n "$last" ] && [ ! -d "$last" ] && last=""
    echo "  [1] Reopen last folder: ${last:-(none)}"
    echo "  [2] Use current folder: $PWD"
    echo "  [3] Enter a path"
    echo "  [b] Back"
    echo -n "  Pick: "
    read -r pick
    case "$pick" in
    1)
        if [ -n "$last" ]; then OPFOLDER="$last"
        else echo "  No saved folder."; return; fi
        ;;
    2) OPFOLDER="$PWD" ;;
    3) echo -n "  Path: "; read -r OPFOLDER ;;
    *) return ;;
    esac
    [ -d "$OPFOLDER" ] || { echo "  Folder not found."; OPFOLDER="$PWD"; return; }
    echo "\"$OPFOLDER\"" > "$LASTFOLDER"
    echo "  Working in: $OPFOLDER"
    log "folder $OPFOLDER" menu
}

# ---------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------
main() {
    mkdir -p "$STATE_DIR"
    trim_log "$LAUNCHER_LOG" "$LOG_MAX_KB"
    log "start v$VERSION args=$*" boot
    lock_check

    [ "$UPDATE_CHECK" = "1" ] && self_update "$@"

    # handle --run quick-start
    if [ "${1:-}" = "--run" ]; then
        shift
        OPFOLDER="${OPFOLDER:-$PWD}"
        find_opencode
        detect_caps
        auto_rotate_loop "$*"
        return
    fi

    # handle a folder passed as argument
    if [ -n "${1:-}" ] && [ -d "$1" ]; then
        OPFOLDER="$(realpath "$1")"
    else
        OPFOLDER="${OPFOLDER:-$PWD}"
    fi

    # pick folder if not set
    [ -d "$OPFOLDER" ] || folder_menu

    # check/install dependencies
    echo ""
    echo "  [dep] Checking dependencies..."

    echo "  [dep] curl"
    have_cmd curl || apt_install curl

    echo "  [dep] opencode"
    find_opencode
    if [ -z "$OC_CMD" ]; then
        echo "  [auto-install] opencode not found, fetching..."
        install_opencode
        find_opencode
    fi
    if [ -z "$OC_CMD" ]; then
        echo -e "${C_ERR}  ERROR: opencode install failed. Get it from https://github.com/sst/opencode/releases${C_RST}"
        exit 1
    fi
    echo -e "${C_OK}  [ok] opencode ready: $OC_CMD  ($OC_VER)${C_RST}"
    detect_caps
    oc_update_check

    # egress menu (first run)
    if [ -z "$EGRESS" ]; then
        settings_menu
    fi
    if [ "$EGRESS" = "WARP" ]; then
        find_warp
        if [ -z "$WARP_BIN" ]; then
            echo -e "${C_WARN}  [!] WARP not found.${C_RST}"
            echo -n "    Install it now? [Y/n]: "
            read -r ans
            if [[ "$ans" =~ ^[Yy]$|^$ ]]; then
                install_warp; find_warp
            fi
            [ -z "$WARP_BIN" ] && { EGRESS=NONE; echo "  Falling back to NONE."; }
        fi
    fi
    if [ "$EGRESS" = "TOR" ]; then
        have_cmd socat || apt_install socat 2>/dev/null || true
    fi

    # main loop
    while true; do
        # Refresh IP display trước khi vẽ menu (chỉ khi đã có proxy)
        if [ -n "$ACTIVE_PROXY" ] || [ "$EGRESS" = "NONE" ]; then
            get_ip "$ACTIVE_PROXY" 2>/dev/null || true
        fi
        show_menu
        read -r choice
        echo ""
        case "$choice" in
        1)
            # Fresh start: kết nối / xoay egress rồi mở
            RESUME=""
            clear
            if [ "$WARP_UP" = "1" ] && [ "$EGRESS" = "WARP" ]; then
                rotate "fresh"
            fi
            auto_rotate_loop
            ;;
        2)
            # Continue: egress cũ, nối tiếp chat
            RESUME=1
            clear
            auto_rotate_loop
            ;;
        3)
            # Change IP only
            clear
            rotate "menu" && get_ip "$ACTIVE_PROXY" && echo "  New IP: ${IP:-unknown}"
            echo ""
            echo -n "  Press Enter to continue..."; read -r
            ;;
        4) folder_menu ;;
        5) deep_reset ;;
        7) token_reset; RESUME=""; clear; auto_rotate_loop ;;
        8) settings_menu; WARP_UP=0; ACTIVE_PROXY="" ;;
        q|Q) break ;;
        *) ;;
        esac
    done
}

main "$@"

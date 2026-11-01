# OpenCode Infinite — Linux (Ubuntu)

> Port của [OpenCode Infinite](https://github.com/jeko1107/opencode-infinite) từ Windows batch sang **bash script cho Ubuntu/Debian**.  
> Tính năng tương đương bản gốc: multi-egress, xoay IP tự động, tự resume chat, bootstrap dependencies.

---

## Tính năng

| Tính năng | Mô tả |
|---|---|
| **Multi-egress** | WARP · Tor · Free HTTP proxies · Direct |
| **Xoay IP tự động** | Khi OpenCode bị rate-limit / quota, tự rotate sang IP mới |
| **Auto-resume** | Gửi lệnh `continue` để nối lại chat trên IP mới |
| **Probe IP** | Kiểm tra IP mới trước khi dùng (bỏ qua IP bị burn) |
| **Bootstrap** | Tự cài `opencode`, `Node.js`, `WARP`, `Tor`, `socat` nếu thiếu |
| **Log watcher** | Theo dõi log, rotate ngay khi thấy lỗi fatal |
| **Self-update** | Tự kiểm tra và cập nhật script mới nhất từ repo |

---

## Yêu cầu hệ thống

- Ubuntu 20.04+ / Debian 11+ (hoặc distro tương tự)
- `bash` 4.x+
- `curl`
- `sudo` (chỉ cần để cài packages lần đầu)

---

## Cài đặt nhanh (1 lệnh)

```bash
curl -fsSL https://raw.githubusercontent.com/Kiyoshi2006/opencode-infinite/linux/opencode-infinite.sh \
  -o ~/opencode-infinite.sh && chmod +x ~/opencode-infinite.sh && ~/opencode-infinite.sh
```

Hoặc clone repo và chạy:

```bash
git clone -b linux https://github.com/Kiyoshi2006/opencode-infinite ~/opencode-infinite
cd ~/opencode-infinite
chmod +x opencode-infinite.sh
./opencode-infinite.sh
```

---

## Cài đặt thủ công

### 1. Tải script

```bash
wget -O ~/opencode-infinite.sh \
  https://raw.githubusercontent.com/Kiyoshi2006/opencode-infinite/linux/opencode-infinite.sh
chmod +x ~/opencode-infinite.sh
```

### 2. Cài dependencies (script sẽ tự cài, nhưng có thể cài trước)

```bash
# Bắt buộc
sudo apt update
sudo apt install -y curl nodejs npm

# Cho chế độ Tor (cần HTTP bridge)
sudo apt install -y tor socat

# Cho chế độ WARP
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
  https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
sudo apt update && sudo apt install -y cloudflare-warp
```

### 3. Chạy

```bash
./opencode-infinite.sh
```

---

## Cách dùng

### Menu chính

Khi khởi động, script hiển thị menu:

```
============================================================
  OpenCode Infinite  v1.0  [Ubuntu]

  Folder : /home/user/myproject
  Egress : WARP
  Proxy  : http://127.0.0.1:40000
  IP     : 104.28.x.x
  OC ver : 2.x.x
============================================================

  [1] Fresh start    - new IP/proxy, open OpenCode
  [2] Continue       - same egress, resume last chat
  [3] Change IP      - rotate / new proxy only
  [4] Change folder  - work in a different folder
  [5] Deep reset     - archive chats, clear tokens, fresh session
  [7] Token reset    - clear tokens, keep chats
  [8] Settings       - change egress
  [q] Quit
```

### Chọn egress (tùy chọn kết nối)

```
  [1] WARP    - Cloudflare WARP (xoay IP tốt nhất)
  [2] TOR     - ẩn danh qua mạng Tor
  [3] PROXY   - dùng danh sách HTTP proxy miễn phí
  [4] NONE    - kết nối trực tiếp, không proxy
```

### Chạy với folder chỉ định

```bash
./opencode-infinite.sh /path/to/your/project
```

### Quick-start (bỏ qua menu, dùng egress đã lưu)

```bash
./opencode-infinite.sh --run
# hoặc kèm tham số opencode
./opencode-infinite.sh --run --model gpt-4o
```

---

## Cấu hình

Mở script và chỉnh phần **SETTINGS** ở đầu file:

```bash
# Số lần thử rotate tối đa
ROTATE_TRIES_MAX=4

# 0 = tìm IP sạch không giới hạn (Ctrl+C để dừng)
IP_FIND_MAX=0

# Giây chờ sau khi kết nối WARP
WARP_WAIT=6

# Giây chờ giữa các lần rotate
ROTATE_COOLDOWN=10

# 1 = tự động rotate khi gặp lỗi fatal trong log
AUTO_ROTATE=1

# Tin nhắn gửi để resume chat
RESUME_MSG="continue"

# Giây timeout cho mỗi lần resume
RESUME_TIMEOUT=90

# Model dùng để probe IP
PROBE_MODEL="opencode/deepseek-v4.1-flash-free"

# 1 = probe IP trước khi dùng (bỏ IP bị burn)
PROBE=1

# Cổng WARP proxy local
# (đặt trong hàm warp_up, mặc định 40000)

# Cổng HTTP bridge cho Tor
TOR_HTTP_PORT=8118

# 1 = tự cài Tor nếu chưa có
TOR_AUTO_INSTALL=1

# URL danh sách proxy miễn phí
PROXY_LIST_URL="https://api.proxyscrape.com/..."

# 1 = tự kiểm tra và cập nhật launcher
UPDATE_CHECK=0
```

---

## Cách hoạt động

```
Khởi động
   │
   ├─ Kiểm tra lock (chống chạy 2 instance)
   ├─ Cài dependency thiếu (opencode, Node, WARP, Tor...)
   ├─ Kết nối egress đã chọn
   │
   └─ Loop:
        ├─ Chạy OpenCode (với HTTP_PROXY set)
        ├─ Theo dõi log (tail -F)
        │    └─ Thấy "rate limit / quota / credits" → rotate
        ├─ Rotate IP (WARP registration mới / Tor circuit mới / proxy mới)
        ├─ Probe IP mới (1 tin nhắn test)
        └─ Gửi "continue" → resume chat trên IP mới
```

---

## Log & debug

```bash
# Xem log của launcher
tail -f ~/.local/share/opencode-infinite/launcher.log

# Xem log của opencode
tail -f ~/.local/share/opencode/log/opencode.log

# Xem log WARP
cat ~/.local/share/opencode-infinite/wcli.log
```

---

## Gỡ lỗi thường gặp

| Lỗi | Nguyên nhân | Cách sửa |
|---|---|---|
| `warp-cli: not found` | WARP chưa cài | Chọn `[8] Settings` → `[1] WARP` rồi đồng ý cài |
| `Tor did not bootstrap` | Tor chưa sẵn sàng | Tăng `TOR_BOOTSTRAP_WAIT=180` |
| `No working free proxy` | List proxy hết | Đổi `PROXY_LIST_URL` hoặc dùng WARP/Tor |
| `opencode: not found` | Node.js / npm lỗi | `sudo apt install -y nodejs npm` thủ công |
| `socat: not found` | Thiếu socat cho Tor bridge | `sudo apt install -y socat` |
| Màn hình trắng / treo | WARP proxy chưa kịp lên | Tăng `WARP_WAIT=10` |

---

## Cấu trúc thư mục

```
~/.local/share/opencode-infinite/
├── launcher.log      ← log của script này
├── wcli.log          ← log warp-cli
├── lastfolder.txt    ← folder cuối cùng đã dùng
├── lock              ← lock file (PID)
└── tor-data/         ← Tor data directory
```

---

## Credit

- Script gốc: [jeko1107/opencode-infinite](https://github.com/jeko1107/opencode-infinite) (Windows)
- Fork & thêm tính năng: [Kiyoshi2006/opencode-infinite](https://github.com/Kiyoshi2006/opencode-infinite)
- Port sang Linux/Ubuntu: branch `linux` của repo này

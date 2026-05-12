/* helper.c — Spinel と POSIX socket / epoll の橋渡し
 *
 * Spinel FFI には次の制約がある:
 *   - sp_runtime.h が stdio/stdlib/string/unistd を include 済 → 衝突回避
 *   - struct を引数に取る関数を直接呼べない (epoll_event 等)
 *   - :ptr バッファを :str に変換する手段がない
 *   - errno を直接読めない (EAGAIN 判定不可)
 * 全部このファイルで吸収する。
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <fcntl.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <sys/random.h>
#include <zlib.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* ---- non-blocking 化 ---- */
int sp_set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* WebSocket 用: O_NONBLOCK を clear。recv が blocking になる
   (1 ws 接続が worker 1 プロセスを占有する。fiber 並行は失う) */
int sp_set_blocking(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return -1;
    return fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);
}

/* ---- epoll: struct epoll_event を組むラッパ ---- */
int sp_epoll_add(int epfd, int fd, uint32_t events) {
    struct epoll_event ev;
    ev.events  = events | EPOLLONESHOT;
    ev.data.fd = fd;
    return epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);
}

int sp_epoll_mod(int epfd, int fd, uint32_t events) {
    struct epoll_event ev;
    ev.events  = events | EPOLLONESHOT;
    ev.data.fd = fd;
    return epoll_ctl(epfd, EPOLL_CTL_MOD, fd, &ev);
}

int sp_epoll_del(int epfd, int fd) {
    return epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL);
}

int sp_epoll_wait_(int epfd, void *evs_out, int max, int timeout_ms) {
    return epoll_wait(epfd, (struct epoll_event *)evs_out, max, timeout_ms);
}

/* i番目の epoll_event の data.fd を読む */
int sp_event_fd(void *evs_buf, int i) {
    struct epoll_event *e = (struct epoll_event *)evs_buf;
    return e[i].data.fd;
}

/* ---- non-blocking 操作: 戻り値 -1=EAGAIN, -2=fatal, それ以外=成功 ---- */
int sp_accept_nb(int fd) {
    int c = accept(fd, NULL, NULL);
    if (c < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
        return -2;
    }
    return c;
}

long sp_recv_nb(int fd, void *buf, size_t cap) {
    if (cap == 0) return -2;
    long n = recv(fd, buf, cap - 1, 0);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
        return -2;
    }
    ((char *)buf)[n] = '\0';
    return n;
}

long sp_send_nb(int fd, const char *buf, size_t len) {
    long n = send(fd, buf, len, MSG_NOSIGNAL);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
        return -2;
    }
    return n;
}

/* sizeof(struct epoll_event) を Spinel 側に教える (動的計算は無いので
   ffi_buffer のサイズ計算用) */
int sp_epoll_event_size(void) {
    return (int)sizeof(struct epoll_event);
}

/* :ptr バッファを :str として読みたい時用のキャストヘルパ。
   呼び出し側が NUL 終端を保証していること */
const char *sp_buf_as_str(void *p) { return (const char *)p; }

/* デバッグログ: stderr に書いて即フラッシュ */
int sp_log(const char *s) {
    fputs(s, stderr);
    fputc('\n', stderr);
    fflush(stderr);
    return 0;
}

/* fork は unistd.h で `__pid_t fork (void) __THROW` と宣言済 →
   ffi_func 直接宣言は属性違いで衝突する可能性があるのでラップする。 */
int sp_fork(void) { return (int)fork(); }
int sp_getpid(void) { return (int)getpid(); }
int sp_waitpid(int pid, int options) {
    int status;
    return (int)waitpid(pid, &status, options);
}

/* SO_REUSEPORT を fd に有効化。ffi_buffer にバイナリ "1" を書き込め
   ないため Ruby 側からは setsockopt を直接呼べない → ラッパで吸収。 */
int sp_set_reuseport(int fd) {
    int one = 1;
    return setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
}

/* TCP_NODELAY を fd に有効化。Nagle を切り、header と body を別 send
   しても 40ms delayed-ACK 待ちが入らないようにする。 */
int sp_set_nodelay(int fd) {
    int one = 1;
    return setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

/* timerfd を作って interval_ms ごとに発火させる。SSE で「N 秒ごとに
   event 送る」のために使う。Spinel スケジューラの epoll に登録すれば
   Fiber.yield → 時間経過で自動 resume が実現できる。 */
int sp_timerfd_create(int interval_ms) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) return -1;
    struct itimerspec ts;
    ts.it_value.tv_sec     = interval_ms / 1000;
    ts.it_value.tv_nsec    = (interval_ms % 1000) * 1000000L;
    ts.it_interval.tv_sec  = ts.it_value.tv_sec;
    ts.it_interval.tv_nsec = ts.it_value.tv_nsec;
    if (timerfd_settime(fd, 0, &ts, NULL) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* timerfd を読み (発火回数を捨て、満了確定だけ得る)。EAGAIN 時は -1 */
int sp_timerfd_read(int fd) {
    uint64_t cnt;
    ssize_t n = read(fd, &cnt, sizeof(cnt));
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
        return -2;
    }
    return (int)cnt;
}

/* unix epoch ミリ秒 (整数) を返す */
long sp_unix_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long)ts.tv_sec * 1000L + (long)(ts.tv_nsec / 1000000);
}

/* gmtime の各成分を space 区切り文字列で返す: "Y M D h m s wday".
   strftime と同じ機能だが「format string」を Ruby 側に持たせるための
   分解 API。これが phase 2 移行の鍵 (helper.c に format string を持たない)。 */
static char sp_gmt_buf[64];
const char *sp_gmtime_str(long epoch_secs) {
    time_t t = (time_t)epoch_secs;
    struct tm tm_;
    gmtime_r(&t, &tm_);
    snprintf(sp_gmt_buf, sizeof(sp_gmt_buf), "%d %d %d %d %d %d %d",
        tm_.tm_year + 1900, tm_.tm_mon + 1, tm_.tm_mday,
        tm_.tm_hour, tm_.tm_min, tm_.tm_sec, tm_.tm_wday);
    return sp_gmt_buf;
}

/* ---- HMAC-SHA256 (Tier 2 #10 用) ----
   key と msg は NUL 終端文字列。戻り値は 64 文字 hex (固定 buf)。 */
static char sp_hmac_hex_buf[65];
const char *sp_hmac_sha256_hex(const char *key, const char *msg) {
    unsigned char digest[32];
    unsigned int len = 32;
    HMAC(EVP_sha256(),
         key, (int)strlen(key),
         (const unsigned char *)msg, strlen(msg),
         digest, &len);
    for (int i = 0; i < 32; i++) {
        snprintf(sp_hmac_hex_buf + i * 2, 3, "%02x", digest[i]);
    }
    sp_hmac_hex_buf[64] = '\0';
    return sp_hmac_hex_buf;
}

/* SHA-256 hex (multipart upload integrity 等)。msg は NUL 終端文字列。 */
static char sp_sha256_hex_buf[65];
const char *sp_sha256_hex(const char *msg) {
    unsigned char digest[32];
    size_t len = 32;
    EVP_Q_digest(NULL, "SHA256", NULL, msg, strlen(msg), digest, &len);
    for (int i = 0; i < 32; i++) {
        snprintf(sp_sha256_hex_buf + i * 2, 3, "%02x", digest[i]);
    }
    sp_sha256_hex_buf[64] = '\0';
    return sp_sha256_hex_buf;
}

/* ---- TLS (Tier 3 #13) — OpenSSL ----
   blocking 同期 TLS。fiber-async との統合は未対応 (worker 1 occupied)。
   実用時は SSL_ERROR_WANT_READ/WRITE をハンドリングして epoll に乗せる。 */
static SSL_CTX *sp_ssl_ctx = NULL;

int sp_ssl_init(const char *cert_path, const char *key_path) {
    if (sp_ssl_ctx) return 0;
    sp_ssl_ctx = SSL_CTX_new(TLS_server_method());
    if (!sp_ssl_ctx) return -1;
    if (SSL_CTX_use_certificate_file(sp_ssl_ctx, cert_path, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(sp_ssl_ctx); sp_ssl_ctx = NULL; return -1;
    }
    if (SSL_CTX_use_PrivateKey_file(sp_ssl_ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(sp_ssl_ctx); sp_ssl_ctx = NULL; return -1;
    }
    return 0;
}

/* fd 上で TLS handshake。成功で SSL* を void* として返す。失敗時 NULL */
void *sp_ssl_accept(int fd) {
    if (!sp_ssl_ctx) return NULL;
    SSL *ssl = SSL_new(sp_ssl_ctx);
    if (!ssl) return NULL;
    SSL_set_fd(ssl, fd);
    if (SSL_accept(ssl) <= 0) {
        SSL_free(ssl);
        return NULL;
    }
    return (void *)ssl;
}

/* TLS 経由で recv (blocking)。NUL 終端で buf に入れ、byte 数返す */
long sp_ssl_recv_to_buf(void *ssl, void *buf, size_t cap) {
    if (cap == 0) return -1;
    int n = SSL_read((SSL *)ssl, buf, (int)(cap - 1));
    if (n <= 0) return -1;
    ((char *)buf)[n] = '\0';
    return (long)n;
}

/* TLS 経由で send (blocking) */
long sp_ssl_send(void *ssl, const char *s) {
    int len = (int)strlen(s);
    int n = SSL_write((SSL *)ssl, s, len);
    return n <= 0 ? -1 : (long)n;
}

void sp_ssl_free(void *ssl) {
    if (!ssl) return;
    SSL_shutdown((SSL *)ssl);
    SSL_free((SSL *)ssl);
}

/* ---- TCP client (SMTP 用, Tier 3 #19) ----
   host:port に同期接続して fd を返す。blocking ソケット。失敗時 -1。 */
int sp_tcp_connect(const char *host, const char *port) {
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    return fd;
}

/* fd から CRLF 区切りで 1 行 recv (blocking)。最大 1023 byte。
   sp_line_buf に NUL終端で格納。戻り値: 行長、または -1 (err/EOF) */
static char sp_line_buf[1024];
int sp_recv_line(int fd) {
    int i = 0;
    while (i < (int)sizeof(sp_line_buf) - 1) {
        char c;
        ssize_t n = recv(fd, &c, 1, 0);
        if (n <= 0) return -1;
        sp_line_buf[i++] = c;
        if (c == '\n') break;
    }
    sp_line_buf[i] = '\0';
    return i;
}

const char *sp_line_buf_str(void) { return sp_line_buf; }

/* fd に文字列を全部 send。失敗 -1。 */
long sp_send_str(int fd, const char *s) {
    size_t len = strlen(s);
    ssize_t total = 0;
    while (total < (ssize_t)len) {
        ssize_t n = send(fd, s + total, len - total, MSG_NOSIGNAL);
        if (n < 0) return -1;
        total += n;
    }
    return (long)total;
}

/* ---- WebSocket (Tier 3 #16) ----
   handshake 用 SHA1 + base64、textフレーム送受信。
   制約: text frame のみ、payload は 125 byte 以下 (extended length 未対応)。 */
static char sp_sha1_b64_buf[40];
const char *sp_sha1_b64(const char *msg) {
    unsigned char digest[20];
    size_t dlen = 20;
    EVP_Q_digest(NULL, "SHA1", NULL, msg, strlen(msg), digest, &dlen);
    int n = EVP_EncodeBlock((unsigned char *)sp_sha1_b64_buf, digest, 20);
    sp_sha1_b64_buf[n] = '\0';
    return sp_sha1_b64_buf;
}

/* WebSocket text frame 受信 (blocking)。戻り値:
     >=0: payload byte 数 (sp_ws_payload に NUL終端 で格納)
     -1:  close frame 受信
     -2:  protocol error / 接続断 */
static char sp_ws_payload[2048];
int sp_ws_recv_text(int fd) {
    unsigned char hdr[2];
    ssize_t n = recv(fd, hdr, 2, 0);
    if (n <= 0) return -2;
    int opcode  = hdr[0] & 0x0F;
    int has_mask = (hdr[1] & 0x80) != 0;
    int len = hdr[1] & 0x7F;
    if (opcode == 0x8) return -1;             /* close */
    if (opcode != 0x1) return -2;             /* not text */
    if (len == 126 || len == 127) return -2;  /* skip extended */
    unsigned char mask[4];
    if (has_mask) {
        if (recv(fd, mask, 4, 0) != 4) return -2;
    }
    if (len > 0) {
        if (recv(fd, sp_ws_payload, len, 0) != len) return -2;
        if (has_mask) {
            for (int i = 0; i < len; i++) sp_ws_payload[i] ^= mask[i & 3];
        }
    }
    sp_ws_payload[len] = '\0';
    return len;
}

/* sp_ws_payload を Spinel 側で参照する用 (recv 直後に呼ぶ) */
const char *sp_ws_payload_str(void) { return sp_ws_payload; }

/* server → client の text frame 送信。MASK ビット無し */
int sp_ws_send_text(int fd, const char *payload) {
    size_t len = strlen(payload);
    if (len > 125) return -1;
    unsigned char hdr[2];
    hdr[0] = 0x81;
    hdr[1] = (unsigned char)len;
    if (send(fd, hdr, 2, MSG_NOSIGNAL) != 2) return -1;
    if (len > 0 && send(fd, payload, len, MSG_NOSIGNAL) != (ssize_t)len) return -1;
    return (int)len;
}

/* ---- bcrypt (Tier 3 #14) — libcrypt 経由 ----
   libxcrypt が "$2b$" 形式の bcrypt をサポート。
   ハッシュ: ランダム 16 byte salt を base64 して `$2b$<cost>$<salt>` を組み、
   crypt(password, salt) で計算。
   検証: crypt(password, stored_hash[最初の29文字]) を計算して定数時間比較。 */
#include <crypt.h>

/* bcrypt 用 base64 文字表 (RFC ではなく BSD 慣習)  */
static const char sp_bcrypt_b64[] =
    "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static void sp_bcrypt_encode_salt(char *out, int cost, const unsigned char *raw16) {
    /* "$2b$10$" + 22 chars (16 byte → 22 chars 6-bit each) */
    out[0] = '$'; out[1] = '2'; out[2] = 'b'; out[3] = '$';
    out[4] = '0' + (cost / 10);
    out[5] = '0' + (cost % 10);
    out[6] = '$';
    /* encode 16 bytes -> 22 chars */
    int i = 0, j = 7;
    while (i < 16) {
        unsigned int c1 = raw16[i++];
        out[j++] = sp_bcrypt_b64[(c1 >> 2) & 0x3F];
        unsigned int c2 = (c1 & 0x03) << 4;
        if (i >= 16) { out[j++] = sp_bcrypt_b64[c2 & 0x3F]; break; }
        c2 |= (raw16[i] >> 4) & 0x0F;
        out[j++] = sp_bcrypt_b64[c2 & 0x3F];
        unsigned int c3 = (raw16[i++] & 0x0F) << 2;
        if (i >= 16) { out[j++] = sp_bcrypt_b64[c3 & 0x3F]; break; }
        c3 |= (raw16[i] >> 6) & 0x03;
        out[j++] = sp_bcrypt_b64[c3 & 0x3F];
        out[j++] = sp_bcrypt_b64[raw16[i++] & 0x3F];
    }
    out[j] = '\0';
}

/* bcrypt ハッシュ生成: $2b$10$... 形式。失敗時 "" */
static char sp_bcrypt_hash_buf[64];
const char *sp_bcrypt_hash(const char *password, int cost) {
    unsigned char salt_raw[16];
    if (getrandom(salt_raw, 16, 0) != 16) return "";
    char salt[32];
    sp_bcrypt_encode_salt(salt, cost, salt_raw);
    char *r = crypt(password, salt);
    if (!r || r[0] == '*') return "";
    size_t len = strlen(r);
    if (len >= sizeof(sp_bcrypt_hash_buf)) return "";
    memcpy(sp_bcrypt_hash_buf, r, len + 1);
    return sp_bcrypt_hash_buf;
}

/* bcrypt 検証: stored の先頭 29 char ($2b$cc$salt22) を salt として
   password を再ハッシュ → stored と定数時間比較。一致 1、不一致 0、err -1 */
int sp_bcrypt_verify(const char *password, const char *stored) {
    if (strlen(stored) < 60) return -1;   /* full bcrypt hash は 60 char */
    char salt[30];
    memcpy(salt, stored, 29);
    salt[29] = '\0';
    char *r = crypt(password, salt);
    if (!r || r[0] == '*') return -1;
    if (strlen(r) != strlen(stored)) return 0;
    /* constant-time compare */
    unsigned char diff = 0;
    for (size_t i = 0; i < strlen(stored); i++) {
        diff |= (unsigned char)r[i] ^ (unsigned char)stored[i];
    }
    return diff == 0 ? 1 : 0;
}

/* ---- gzip (Tier 3 #20) ----
   src を gzip 形式 (raw deflate + gzip ヘッダ) で圧縮し内部 buf に格納、
   byte 数を返す。後で sp_send_gzipped で送信。
   Spinel :str は NUL 含むバイナリを保持できないため、Ruby に bytes を
   返す代わりに「圧縮 → 送る」を C 側で完結させる設計。 */
static unsigned char sp_gzip_buf[65536];
static size_t sp_gzip_len = 0;

int sp_gzip(const char *src) {
    size_t src_len = strlen(src);
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                     15 + 16,  /* windowBits + 16 = gzip wrapper */
                     8, Z_DEFAULT_STRATEGY) != Z_OK) return -1;
    zs.next_in   = (Bytef *)(uintptr_t)src;
    zs.avail_in  = (uInt)src_len;
    zs.next_out  = sp_gzip_buf;
    zs.avail_out = sizeof(sp_gzip_buf);
    int rc = deflate(&zs, Z_FINISH);
    sp_gzip_len = zs.total_out;
    deflateEnd(&zs);
    if (rc != Z_STREAM_END) return -1;
    return (int)sp_gzip_len;
}

/* gzip buffer の内容を fd に send。失敗時 -1、成功で送信 byte 数 */
long sp_send_gzipped(int fd) {
    ssize_t total = 0;
    while (total < (ssize_t)sp_gzip_len) {
        ssize_t n = send(fd, sp_gzip_buf + total,
                         sp_gzip_len - total, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;  /* 簡易: spin */
            return -1;
        }
        total += n;
    }
    return (long)total;
}

/* 定数時間文字列比較 (タイミング攻撃対策)。長さが違えば即 false。
   両方が同じ長さなら全 byte XOR を OR で集約。 */
int sp_consttime_eq(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    if (la != lb) return 0;
    unsigned char diff = 0;
    for (size_t i = 0; i < la; i++) {
        diff |= (unsigned char)a[i] ^ (unsigned char)b[i];
    }
    return diff == 0 ? 1 : 0;
}

/* UUID v4 / v7 (RFC 4122 / RFC 9562)。
   Spinel の :str FFI 戻り値は内部で sp_str_dup_external しているはずだが、
   v4 + v7 を同一式で評価すると後の呼び出しが先の static buf を
   上書きするケースがあった (concat 前の評価順依存)。
   v4 と v7 でバッファを分けることで安全側に倒す。 */
static char sp_uuid_buf_v4[37];
static char sp_uuid_buf_v7[37];

static void sp_format_uuid_to(char *out, const unsigned char *b) {
    snprintf(out, 37,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[0],b[1],b[2],b[3], b[4],b[5], b[6],b[7], b[8],b[9],
        b[10],b[11],b[12],b[13],b[14],b[15]);
}

const char *sp_uuid_v4(void) {
    unsigned char b[16];
    if (getrandom(b, 16, 0) != 16) return "";
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    sp_format_uuid_to(sp_uuid_buf_v4, b);
    return sp_uuid_buf_v4;
}

const char *sp_uuid_v7(void) {
    unsigned char b[16];
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    uint64_t ms = (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000);
    b[0] = (ms >> 40) & 0xFF;
    b[1] = (ms >> 32) & 0xFF;
    b[2] = (ms >> 24) & 0xFF;
    b[3] = (ms >> 16) & 0xFF;
    b[4] = (ms >> 8)  & 0xFF;
    b[5] =  ms        & 0xFF;
    if (getrandom(b + 6, 10, 0) != 10) return "";
    b[6] = (b[6] & 0x0F) | 0x70;
    b[8] = (b[8] & 0x3F) | 0x80;
    sp_format_uuid_to(sp_uuid_buf_v7, b);
    return sp_uuid_buf_v7;
}

/* SIGTERM/SIGINT を signalfd 化して epoll で待てるようにする。
   sigprocmask でデフォルト配送を止め、signalfd 経由でのみ受け取る。 */
int sp_signalfd_create(void) {
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGHUP);
    if (sigprocmask(SIG_BLOCK, &mask, NULL) < 0) return -1;
    return signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
}

/* signalfd から 1 件読む。戻り値は signo (>0)、EAGAIN なら -1、その他エラー -2 */
int sp_signalfd_read(int fd) {
    struct signalfd_siginfo si;
    ssize_t n = read(fd, &si, sizeof(si));
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
        return -2;
    }
    if (n != (ssize_t)sizeof(si)) return -2;
    return (int)si.ssi_signo;
}

int sp_kill(int pid, int sig) {
    return kill((pid_t)pid, sig);
}

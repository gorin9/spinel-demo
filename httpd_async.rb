# Spinel async HTTP server: Fiber + epoll, single-threaded non-blocking.

module C
  ffi_func :socket,       [:int, :int, :int],          :int
  ffi_func :bind,         [:int, :ptr, :uint32],       :int
  ffi_func :listen,       [:int, :int],                :int
  ffi_func :close,        [:int],                      :int
  ffi_func :getaddrinfo,  [:str, :str, :ptr, :ptr],    :int
  ffi_func :freeaddrinfo, [:ptr],                      :void
  ffi_func :gai_strerror, [:int],                      :str
  ffi_func :perror,       [:str],                      :void
  ffi_func :epoll_create1,[:int],                      :int

  ffi_buffer :ai_out,    8
  ffi_read_u32 :ai_addrlen, 16
  ffi_read_ptr :ai_addr,    24
  ffi_read_ptr :deref_ptr,   0
end

module SQL
  ffi_lib "sqlite3"
  ffi_const :OK,   0
  ffi_const :ROW,  100
  ffi_const :DONE, 101
  ffi_func :sqlite3_open,        [:str, :ptr],                          :int
  ffi_func :sqlite3_close,       [:ptr],                                :int
  ffi_func :sqlite3_exec,        [:ptr, :str, :ptr, :ptr, :ptr],        :int
  ffi_func :sqlite3_prepare_v2,  [:ptr, :str, :int, :ptr, :ptr],        :int
  ffi_func :sqlite3_step,        [:ptr],                                :int
  ffi_func :sqlite3_finalize,    [:ptr],                                :int
  ffi_func :sqlite3_column_int,  [:ptr, :int],                          :int
  ffi_func :sqlite3_column_text, [:ptr, :int],                          :str
  ffi_func :sqlite3_errmsg,      [:ptr],                                :str
  ffi_buffer :db_out,    8
  ffi_buffer :stmt_out,  8
  ffi_read_ptr :read_ptr, 0
end

# Q: 薄いクエリビルダ。SQL injection 防止のための quote 関数を中心に、
# 共通操作用の SQL 文字列ビルダを公開する (Tier 2 #7)。
module Q
  # SQL 文字列リテラル中の single quote をエスケープ
  def self.q(s)
    s.gsub("'", "''")
  end
end

module H
  ffi_lib    "spinelhelper"
  ffi_lib    "crypto"            # OpenSSL libcrypto for HMAC / SHA
  ffi_lib    "ssl"               # OpenSSL libssl for TLS
  ffi_lib    "z"                 # zlib for gzip
  ffi_lib    "crypt"             # libxcrypt for bcrypt
  ffi_cflags "-L/opt/spinel-helper"

  ffi_func :sp_set_nonblock, [:int],                       :int
  ffi_func :sp_set_blocking, [:int],                       :int
  ffi_func :sp_epoll_add,    [:int, :int, :uint32],        :int
  ffi_func :sp_epoll_del,    [:int, :int],                 :int
  ffi_func :sp_epoll_wait_,  [:int, :ptr, :int, :int],     :int
  ffi_func :sp_event_fd,     [:ptr, :int],                 :int
  ffi_func :sp_accept_nb,    [:int],                       :int
  ffi_func :sp_recv_nb,      [:int, :ptr, :size_t],        :long
  ffi_func :sp_send_nb,      [:int, :str, :size_t],        :long
  ffi_func :sp_buf_as_str,   [:ptr],                       :str
  ffi_func :sp_log,          [:str],                       :int
  ffi_func :sp_fork,         [],                           :int
  ffi_func :sp_getpid,       [],                           :int
  ffi_func :sp_waitpid,      [:int, :int],                 :int
  ffi_func :sp_set_reuseport,[:int],                       :int
  ffi_func :sp_set_nodelay,  [:int],                       :int
  ffi_func :sp_timerfd_create,[:int],                      :int
  ffi_func :sp_timerfd_read, [:int],                       :int
  ffi_func :sp_unix_ms,      [],                           :long
  ffi_func :sp_gmtime_str,   [:long],                      :str
  ffi_func :sp_uuid_v4,      [],                           :str
  ffi_func :sp_uuid_v7,      [],                           :str
  ffi_func :sp_hmac_sha256_hex,[:str, :str],               :str
  ffi_func :sp_sha256_hex,   [:str],                       :str
  ffi_func :sp_consttime_eq, [:str, :str],                 :int
  ffi_func :sp_gzip,         [:str],                       :int
  ffi_func :sp_send_gzipped, [:int],                       :long
  ffi_func :sp_bcrypt_hash,  [:str, :int],                 :str
  ffi_func :sp_bcrypt_verify,[:str, :str],                 :int
  ffi_func :sp_sha1_b64,     [:str],                       :str
  ffi_func :sp_ws_recv_text, [:int],                       :int
  ffi_func :sp_ws_payload_str,[],                          :str
  ffi_func :sp_ws_send_text, [:int, :str],                 :int
  ffi_func :sp_tcp_connect,  [:str, :str],                 :int
  ffi_func :sp_recv_line,    [:int],                       :int
  ffi_func :sp_line_buf_str, [],                           :str
  ffi_func :sp_send_str,     [:int, :str],                 :long
  ffi_func :sp_ssl_init,     [:str, :str],                 :int
  ffi_func :sp_ssl_accept,   [:int],                       :ptr
  ffi_func :sp_ssl_recv_to_buf,[:ptr, :ptr, :size_t],      :long
  ffi_func :sp_ssl_send,     [:ptr, :str],                 :long
  ffi_func :sp_ssl_free,     [:ptr],                       :void
  ffi_func :sp_signalfd_create, [],                        :int
  ffi_func :sp_signalfd_read,[:int],                       :int
  ffi_func :sp_kill,         [:int, :int],                 :int

  ffi_buffer :events_buf, 768
  ffi_buffer :req_buf,    4096
end

PORT = "8080"
ROOT = "."

require_relative "web/date"
require_relative "web/logger"
require_relative "web/session"
require_relative "web/mime"
require_relative "web/multipart"
require_relative "web/csrf"
require_relative "web/bcrypt"
require_relative "web/websocket"
require_relative "web/smtp"
require_relative "web/tls"

# Fiber wrapper for obj_*_ptr_array typing.
require_relative "web/scheduler"

# 静的ファイルキャッシュ — トップレベル定数で持つ。
INDEX_HTML = File.exist?(ROOT + "/index.html") ? File.read(ROOT + "/index.html") : ""
ABOUT_HTML = File.exist?(ROOT + "/about.html") ? File.read(ROOT + "/about.html") : ""
STYLE_CSS  = File.exist?(ROOT + "/style.css")  ? File.read(ROOT + "/style.css")  : ""
APP_JS     = File.exist?(ROOT + "/app.js")     ? File.read(ROOT + "/app.js")     : ""

# (Scheduler / FB / SCHED / nb_* / run_signal_watch は web/scheduler.rb に移動)

# ---- HTTP -------------------------------------------------------
def parse_path(line)
  i = line.index(" ")
  return "/" if i < 0
  rest = line.slice(i + 1, line.length)
  j = rest.index(" ")
  return rest if j < 0
  rest.slice(0, j)
end

# SSE: 1 秒ごとに `event: tick\ndata: <iso>\n\n` を送る。
# timerfd を epoll に組み込んで、Fiber.yield で時間経過 → resume する。
# クライアント切断 (send EAGAIN→error) で fiber 終了。
def serve_sse(cfd)
  hdr = "HTTP/1.1 200 OK\r\n" \
      + "Content-Type: text/event-stream\r\n" \
      + "Cache-Control: no-cache\r\n" \
      + "Connection: keep-alive\r\n\r\n"
  if !nb_send_all(cfd, hdr)
    return
  end

  tfd = H.sp_timerfd_create(1000)
  if tfd < 0
    return
  end

  alive = true
  count = 0
  while alive
    # timerfd が満了すると epoll で起こされる
    SCHED.wait_io(tfd, 1)            # EPOLLIN
    H.sp_timerfd_read(tfd)           # 発火数を読み捨て
    count = count + 1

    msg = "event: tick\r\n" \
        + "id: " + count.to_s + "\r\n" \
        + "data: " + iso_now + "\r\n\r\n"

    if !nb_send_all(cfd, msg)
      alive = false                  # client closed
    end
    if count >= 60
      alive = false                  # 60 イベントで safety close
    end
  end

  C.close(tfd)
end

def respond_v11(cfd, status, ctype, body, conn_close)
  conn_hdr = conn_close ? "close" : "keep-alive"
  # TCP_NODELAY 有効ゆえ 2 send で OK (Nagle 無し → delayed-ACK 待ち無し)。
  # body と連結を避けることで 1 req あたりの string alloc を削減。
  hdr = "HTTP/1.1 " + status + "\r\n" \
      + "Content-Type: " + ctype + "\r\n" \
      + "Content-Length: " + body.bytesize.to_s + "\r\n" \
      + "Connection: " + conn_hdr + "\r\n\r\n"
  return false unless nb_send_all(cfd, hdr)
  nb_send_all(cfd, body)
end

# Set-Cookie 付き版 (#10 セッション用)
def respond_v11_cookie(cfd, status, ctype, body, conn_close, set_cookie)
  conn_hdr = conn_close ? "close" : "keep-alive"
  hdr = "HTTP/1.1 " + status + "\r\n" \
      + "Content-Type: " + ctype + "\r\n" \
      + "Content-Length: " + body.bytesize.to_s + "\r\n" \
      + "Set-Cookie: " + set_cookie + "\r\n" \
      + "Connection: " + conn_hdr + "\r\n\r\n"
  return false unless nb_send_all(cfd, hdr)
  nb_send_all(cfd, body)
end

# 1 接続を keep-alive で複数リクエスト処理する。
# 簡易実装: 1 recv = 1 完全なリクエスト前提 (パイプライン不可)。
def serve(cfd)
  H.sp_set_nonblock(cfd)
  H.sp_set_nodelay(cfd)
  alive = true
  req_count = 0
  while alive
    n = nb_recv(cfd, H.req_buf, 4096)
    if n <= 0
      alive = false
    else
      s = H.sp_buf_as_str(H.req_buf)
      nl = s.index("\n")
      line = nl < 0 ? s : s.slice(0, nl)
      path = parse_path(line)

      # Connection 判定 (s に対する include? は alloc しない)
      want_close = line.include?("HTTP/1.0") || \
                   s.include?("Connection: close") || \
                   s.include?("connection: close")

      req_count = req_count + 1
      # 安全弁: 1 接続あたり最大 20 リクエスト (Spinel GC が長寿命 fiber で不安定なため低めに)
      if req_count >= 20
        want_close = true
      end

      log_info("GET " + path)

      if path == "/events"
        # SSE: ストリーミングモード。serve_sse 内で完結、終わったら conn 閉じる。
        serve_sse(cfd)
        alive = false
      elsif path == "/uuid"
        body = "{\"v4\":\"" + H.sp_uuid_v4 + "\",\"v7\":\"" + H.sp_uuid_v7 + "\"}\n"
        respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
        alive = false if want_close
      elsif path == "/ws"
        serve_websocket(cfd, s)
        alive = false   # WebSocket は keep-alive 経路に戻さない
      elsif path == "/smtp-demo"
        # SMTP client ライブラリのデモ。localhost:25 に dummy 送信を試す。
        # 接続失敗するのが普通 (n1 に SMTP 受け側無いはず) — 動作確認用。
        ok = smtp_send("localhost", "25", "from@example.com", "to@example.com",
                       "Subject: hi\r\nFrom: from@example.com\r\nTo: to@example.com\r\n\r\nhello\r\n")
        body = "{\"sent\":" + (ok ? "true" : "false") + "}\n"
        respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
        alive = false if want_close
      elsif path == "/tls-demo"
        # TLS init を試す。cert/key 未配置なので普通失敗する (-1)。
        rc = tls_init("/etc/ssl/private/cert.pem", "/etc/ssl/private/key.pem")
        body = "{\"init_rc\":" + rc.to_s + ",\"note\":\"library available, requires PEM files\"}\n"
        respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
        alive = false if want_close
      elsif path.index("/bcrypt") == 0
        # /bcrypt?p=password → hash + 自己検証
        pos = path.index("p=")
        pw = pos < 0 ? "test123" : path.slice(pos + 2, path.length)
        hash = bc_hash(pw, 10)
        ok = bc_verify(pw, hash)
        wrong = bc_verify(pw + "x", hash)
        body = "{\"hash\":\"" + hash + "\",\"self_verify\":" + (ok ? "true" : "false") \
             + ",\"wrong_verify\":" + (wrong ? "true" : "false") + "}\n"
        respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
        alive = false if want_close
      elsif path == "/gz"
        # Content-Encoding: gzip で INDEX_HTML を配信
        gz_len = H.sp_gzip(INDEX_HTML)
        if gz_len <= 0
          respond_v11(cfd, "500 Internal", "text/plain", "gzip failed\n", want_close)
        else
          hdr = "HTTP/1.1 200 OK\r\n" \
              + "Content-Type: text/html; charset=utf-8\r\n" \
              + "Content-Encoding: gzip\r\n" \
              + "Content-Length: " + gz_len.to_s + "\r\n" \
              + "Connection: " + (want_close ? "close" : "keep-alive") + "\r\n\r\n"
          if nb_send_all(cfd, hdr)
            H.sp_send_gzipped(cfd)
          end
        end
        alive = false if want_close
      elsif path == "/csrf"
        # 既存 cookie の token を再利用、無ければ新規発行
        existing = get_csrf_cookie(s)
        tok = existing == "" ? csrf_token : existing
        body = "{\"csrf_token\":\"" + tok + "\"}\n"
        ck = "csrf_token=" + tok + "; Path=/; HttpOnly; SameSite=Strict"
        respond_v11_cookie(cfd, "200 OK", "application/json; charset=utf-8", body, want_close, ck)
        alive = false if want_close
      elsif path.index("/csrf/verify") == 0
        # query string ?token=XXX を取り、cookie と比較
        submitted = get_query_token(path)
        expected  = get_csrf_cookie(s)
        ok = csrf_valid?(submitted, expected)
        body = "{\"valid\":" + (ok ? "true" : "false") + "}\n"
        respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
        alive = false if want_close
      elsif path == "/session"
        signed = get_session_cookie(s)
        user = session_verify(signed)
        if user == ""
          user = H.sp_uuid_v7
          new_signed = session_sign(user)
          body = "{\"new\":true,\"user\":\"" + user + "\"}\n"
          ck = "session=" + new_signed + "; Path=/; HttpOnly; SameSite=Strict"
          respond_v11_cookie(cfd, "200 OK", "application/json; charset=utf-8", body, want_close, ck)
        else
          body = "{\"existing\":true,\"user\":\"" + user + "\"}\n"
          respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
        end
        alive = false if want_close
      elsif path == "/upload"
        serve_upload(cfd, s, want_close)
        alive = false   # POST 後は keep-alive せず閉じる (簡易版)
      elsif path == "/users"
        serve_users(cfd, want_close)
        alive = false if want_close
      elsif path == "/now"
        body = "{\"iso\":\""     + iso_now          + "\"," \
             + "\"rfc2822\":\""  + rfc2822_now      + "\"," \
             + "\"http\":\""     + http_date_now    + "\"," \
             + "\"unix_ms\":"    + H.sp_unix_ms.to_s + "}\n"
        respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
        alive = false if want_close
      elsif path.include?("..")
        log_warn("bad path: " + path)
        respond_v11(cfd, "400 Bad Request", "text/plain", "bad path\n", want_close)
        alive = false if want_close
      elsif path == "/"
        respond_v11(cfd, "200 OK", mime_for("/index.html"), INDEX_HTML, want_close)
        alive = false if want_close
      elsif path == "/about.html"
        respond_v11(cfd, "200 OK", mime_for(path), ABOUT_HTML, want_close)
        alive = false if want_close
      elsif path == "/style.css"
        respond_v11(cfd, "200 OK", mime_for(path), STYLE_CSS, want_close)
        alive = false if want_close
      elsif path == "/app.js"
        respond_v11(cfd, "200 OK", mime_for(path), APP_JS, want_close)
        alive = false if want_close
      else
        respond_v11(cfd, "404 Not Found", "text/plain", "not found\n", want_close)
        alive = false if want_close
      end
    end
  end
  C.close(cfd)
end

# ---- main -------------------------------------------------------
def setup_listen
  rc = C.getaddrinfo("0.0.0.0", PORT, nil, C.ai_out)
  if rc != 0
    puts "getaddrinfo: " + C.gai_strerror(rc); exit(1)
  end
  ai      = C.deref_ptr(C.ai_out)
  addr    = C.ai_addr(ai)
  addrlen = C.ai_addrlen(ai)
  fd = C.socket(2, 1, 0)
  # SO_REUSEPORT: 各 worker が独立 listen socket を同 port に持ち、
  # kernel が 4-tuple ハッシュで接続を分配する。thundering herd 回避。
  H.sp_set_reuseport(fd)
  if C.bind(fd, addr, addrlen) != 0
    C.perror("bind"); exit(1)
  end
  if C.listen(fd, 1024) != 0
    C.perror("listen"); exit(1)
  end
  C.freeaddrinfo(ai)
  H.sp_set_nonblock(fd)
  fd
end

def run_acceptor
  forever = true
  while forever
    if SCHED.shutdown?
      forever = false
    else
      cfd = nb_accept(SCHED.listen_fd)
      if cfd >= 0
        SCHED.push_cfd(cfd)
        worker = Fiber.new { run_worker }
        SCHED.add_ready(worker)
      elsif cfd == -1
        # listen_fd が close された (graceful shutdown) → 終了
        forever = false
      end
    end
  end
end

def run_worker
  cfd = SCHED.pop_cfd
  serve(cfd)
end

def preload_cache
  H.sp_log("cache: index=" + INDEX_HTML.bytesize.to_s + " about=" + ABOUT_HTML.bytesize.to_s)
end

def init_db
  rc = SQL.sqlite3_open(":memory:", SQL.db_out)
  if rc != 0
    H.sp_log("sqlite3_open failed rc=" + rc.to_s); exit(1)
  end
  db = SQL.read_ptr(SQL.db_out)
  SQL.sqlite3_exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", nil, nil, nil)
  # 3 件 seed
  names = ["alice", "bob", "carol"]
  i = 0
  while i < names.length
    sql = "INSERT INTO users (name) VALUES ('" + Q.q(names[i]) + "')"
    SQL.sqlite3_exec(db, sql, nil, nil, nil)
    i += 1
  end
  H.sp_log("db: seeded users")
end

def serve_upload(cfd, s, want_close)
  boundary = get_boundary(s)
  if boundary == ""
    respond_v11(cfd, "400 Bad Request", "text/plain", "missing multipart boundary\n", want_close)
    return
  end
  content = parse_multipart_first(s, boundary)
  body = "{\"boundary\":\"" + boundary + "\",\"size\":" + content.bytesize.to_s + ",\"sha256\":\"" + H.sp_sha256_hex(content) + "\"}\n"
  respond_v11(cfd, "200 OK", "application/json; charset=utf-8", body, want_close)
end

def serve_users(cfd, want_close)
  db = SQL.read_ptr(SQL.db_out)
  SQL.sqlite3_prepare_v2(db, "SELECT id, name FROM users ORDER BY id", -1, SQL.stmt_out, nil)
  stmt = SQL.read_ptr(SQL.stmt_out)
  json = "["
  first = true
  loop_done = false
  while !loop_done
    rc = SQL.sqlite3_step(stmt)
    if rc == SQL::ROW
      id = SQL.sqlite3_column_int(stmt, 0)
      name = SQL.sqlite3_column_text(stmt, 1)
      if !first
        json = json + ","
      end
      first = false
      json = json + "{\"id\":" + id.to_s + ",\"name\":\"" + name + "\"}"
    else
      loop_done = true
    end
  end
  json = json + "]\n"
  SQL.sqlite3_finalize(stmt)
  respond_v11(cfd, "200 OK", "application/json; charset=utf-8", json, want_close)
end

puts "async httpd on http://0.0.0.0:" + PORT + "/"

# N 並列 (SO_REUSEPORT)。親は child PIDs を覚える。
# キャッシュは fork 後に各 worker が個別ロード (Spinel GC が
# 親-子間の COW を保てないため、共有 read-only キャッシュは
# crash する。各 worker が独自コピーを持つしかない)。
N_WORKERS = 4
i = 1
is_child = false
while i < N_WORKERS
  pid = H.sp_fork
  if pid == 0
    is_child = true
    i = N_WORKERS
  elsif pid < 0
    H.sp_log("fork failed"); exit(1)
  else
    SCHED.add_child_pid(pid)
    i += 1
  end
end

H.sp_log("worker pid=" + H.sp_getpid.to_s + " starting (child=" + is_child.to_s + ")")

SCHED.boot
SCHED.listen_fd = setup_listen
SCHED.sigfd     = H.sp_signalfd_create
preload_cache    # fork 後ロード — 各 worker が独立コピーを持つ
init_db          # 各 worker が独立 in-memory db を持つ

acceptor    = Fiber.new { run_acceptor }
sig_watcher = Fiber.new { run_signal_watch }
SCHED.add_ready(acceptor)
SCHED.add_ready(sig_watcher)
SCHED.run

H.sp_log("worker pid=" + H.sp_getpid.to_s + " exit clean")

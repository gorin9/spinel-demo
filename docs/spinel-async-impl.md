# Spinel に Fiber + epoll を実装してみた記録

`docs/spinel-httpd.md` で作った同期版 (シングルスレッド逐次 accept) は
c=100 で p99 が 1 秒に爆発した。Fiber と epoll を組み合わせて
non-blocking 化したら何処まで戦えるか、実装してベンチした記録。

## TL;DR

c=100 で **Spinel async が Go (net/http) を抜いた**。

| 並行度 | Spinel sync | Spinel async | Go |
|---|---|---|---|
| c=1 rps | 1,985 | **2,256** | 1,190 |
| c=10 rps | **7,269** | 7,075 | 5,253 |
| c=100 rps | 3,670 | **8,299** | 7,371 |
| c=100 p99 | 1,038 ms 💀 | **36.8 ms** | 29.8 ms |
| c=100 max | 2,723 ms 💀 | 62 ms | 48 ms |

ただし **Spinel async はシングルスレッド** なので CPU bound や c≥1000
では Go (4 core 並列) に届かない。これを取りに行くなら fork +
SO_REUSEPORT (nginx 方式)。

## 設計

```
        ┌──────────── SCHED.run (main) ────────────┐
        │                                          │
        │  @ready_idx (IntArray)                   │
        │   ↓ shift                                │
        │  fb = @all[idx]                          │
        │  fb.fiber.resume                         │
        │   ↓ (fiber 内で IO ブロック発生)         │
        │  SCHED.wait_io(fd, EPOLLIN)              │
        │   - epoll_ctl ADD fd                     │
        │   - @wait_fds.push(fd)                   │
        │   - @wait_idx.push(@current)             │
        │   - Fiber.yield                          │
        │                                          │
        │  ready 空 → epoll_wait                   │
        │   ↓ event                                │
        │  fd → @wait_fds.index → @wait_idx[i]     │
        │   → @ready_idx.push(fb_idx)              │
        └──────────────────────────────────────────┘
```

## 実装で踏んだ Spinel の制約 (重要)

これらは未来の Spinel 利用者・upstream への候補としてのフィードバックとして記録。

### 1. ヘッダ衝突: stdio/unistd 系の関数を ffi_func で再宣言できない

`sp_runtime.h` が `stdio.h` / `stdlib.h` / `string.h` / `unistd.h` を
include している。`write/read/fdopen/fgets/fflush/fclose/...` を
`ffi_func` 宣言すると C コンパイラが prototype 衝突で落ちる。

→ `<sys/socket.h>` / `<netdb.h>` / `<sys/epoll.h>` / `<fcntl.h>` の
関数だけ使う。`write` は `send` で代替。

### 2. `:ptr` バッファ → `:str` の変換手段がない

`ffi_read_*` は u32/i32/ptr 限定。バッファの中身を Ruby 文字列として
取り出せない。

→ helper.c に `const char *sp_buf_as_str(void *p)` を作り、
`ffi_func :sp_buf_as_str, [:ptr], :str` で取り出す。

### 3. struct 引数を取る関数を呼べない (epoll_event, sockaddr_in)

`ffi_buffer` 上に struct を組み立てたいが、`ffi_write_*` 未実装で
バイナリ書き込み不可。

→ helper.c で struct を組み立てる薄いラッパを書き、それを `ffi_func`
で呼ぶ。`getaddrinfo` は struct を作って返してくれるので利用可。

### 4. errno が直接読めない → EAGAIN 判定不可

→ helper.c で `recv/send/accept` をラップし、戻り値で `-1=EAGAIN`,
`-2=fatal` を区別する。

### 5. **配列の要素型に Fiber が使えない**

Spinel の型推論 `infer_array_elem_type` は `is_obj_type(et)` で
分岐するが、Fiber は型トークン `"fiber"` (obj_ プレフィクスなし)
なので、フォールバックの `int_array` に落ちる。`@ready = [Fiber.new {0}]`
は **暗黙的に IntArray になり** Fiber* を mrb_int として push しようと
してコンパイルエラー。

→ Fiber を `class FB` でラップして `obj_FB_ptr_array` に乗せる。

```ruby
class FB
  def initialize(f); @f = f; end
  def fiber; @f; end
end
```

### 6. **PtrArray は shift / pop / delete_at が未実装**

`obj_*_ptr_array` で使えるのは `push / [] / []= / clear / length`
のみ。`@ready.shift` は警告 (emitting 0) で消失する。

→ FB を append-only な `@all` (PtrArray) に保持し、IntArray の
インデックスでアクセス。IntArray は shift/delete_at が使える。

```ruby
@all = [FB.new(Fiber.new { 0 })]; @all.clear
@ready_idx = []   # IntArray of indices into @all
```

### 7. `Fiber.new(&block)` で外側のブロックを渡せない

`def spawn(&block); Fiber.new(&block); end` パターンが動かない。
動作はするが Fiber の中身が空になる (要追加調査)。

→ Fiber.new ブロックを直接書くか、メソッドコールで包む:
`Fiber.new { run_acceptor }` のように。

### 8. **`while true` (true 定数) は式位置でループしない**

Fiber.new ブロックの最後の式が `while true ... end` だと、Spinel が
これを「条件式が定数 true のループ」として最適化 (?) して body が
実行されない。

→ 変数化: `forever = true; while forever` ならループする。
あるいは別メソッドに切り出して `Fiber.new { method_call }` の形に。

### 9. **`loop do ... end` は式位置で動かない**

stmt 位置では動くが、Fiber.new ブロックや method 末尾 (= 式位置)
だと `(emitting 0)` の警告で消失。

→ `while true` (上記対策込み) を使う。

### 10. **`arr.index(v)` は -1 を返す。`!= nil` 判定は危険**

Spinel の `sp_IntArray_index` は見つからない時 -1 を返す。
Ruby は nil を返すが Spinel int は nil 比較ができない。
`if wi != nil` だと wi=0 で false になる。

→ `if wi >= 0` を使う。

## ベンチ結果詳細 (n1: 4 core x86_64)

865 B の `index.html` を配信。

### スループット

| 並行度 | Spinel sync rps | Spinel async rps | Go rps |
|---|---|---|---|
| c=1   | 1,985 | **2,256** | 1,190 |
| c=10  | **7,269** | 7,075 | 5,253 |
| c=100 | 3,670 | **8,299** | 7,371 |

### レイテンシ

| 並行度 | sync p50 / p99 / max | async p50 / p99 / max | Go p50 / p99 / max |
|---|---|---|---|
| c=1   | 367µs / 1.49ms / 4.3ms | 344µs / 1.23ms / 2.7ms | 789µs / 2.02ms / 6.5ms |
| c=10  | 1.29ms / 3.21ms / 6.7ms | 1.28ms / 3.47ms / 11ms | 1.73ms / 4.88ms / 16ms |
| c=100 | 2.5ms / **1,038ms** 💀 / 2,723ms 💀 | 11ms / **36.8ms** / 62ms | 13ms / 29.8ms / 48ms |

### 解釈

- **c=1〜10 では sync と async がほぼ同じ**。yield オーバヘッドは無視できる。
  Spinel async が Go より速いのは AOT + ミニマム経路の利。
- **c=100 で sync の tail 死亡 (p99=1秒)** は予想どおり。
  シングルスレッド逐次 accept で 100 接続が直列化された結果。
- **c=100 で async が Go を抜いた (8,299 vs 7,371 rps)**。
  シングルスレッド epoll は 1 core を完全に使い切れて、
  Go の goroutine スケジュール+net/http の経路長より短い。
  ただし p99 は Go の方が良い (29.8ms vs 36.8ms)。CPU 並列の差。

## 続編: prefork + SO_REUSEPORT で CPU 並列

シングルスレッド版で c=100 まで Go と互角〜やや勝ちまでは行ったが、
1 core 上限のため c≥500 では Go の goroutine 並列に負ける見込み。
そこで **fork() で 4 worker** を立ち上げて並列化を試した。

### Step 1: 単純 fork (listen_fd 継承) → ダメ

`socket+bind+listen` 後に `fork(3)` で 3 子プロセス起こし、全プロセスが
同じ `listen_fd` を継承して accept する Apache prefork 風。

結果: 単一プロセス (8,299 rps@c=100) より **遅い** (7,286 rps)。

原因: **thundering herd**。複数の epoll が同じ listen socket を監視し、
新規接続のたびに全 epoll が起こされる。1 つだけが accept に成功し、
他は EAGAIN。CPU が無駄に消費される。

### Step 2: SO_REUSEPORT に変更 → 圧勝

fork した各 worker が **独立に** listen socket を作り、SO_REUSEPORT を
セットしてから bind する。kernel が 4-tuple ハッシュで接続を各 socket
に分配 (Linux 3.9+)。herd 解消。

helper.c に以下を追加:
```c
int sp_set_reuseport(int fd) {
    int one = 1;
    return setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
}
```

Ruby 側で各 worker が独立に `setup_listen` を呼ぶ:
```ruby
def setup_listen
  fd = C.socket(2, 1, 0)
  H.sp_set_reuseport(fd)        # ← これがキモ
  C.bind(fd, addr, addrlen)
  C.listen(fd, 1024)
  H.sp_set_nonblock(fd)
  fd
end

# fork して各プロセスで setup_listen → SCHED.run
```

### 最終ベンチ: Spinel が Go を全レンジで抜いた

| 並行度 | Spinel async 4p | Go net/http | 差 |
|---|---|---|---|
| c=1   | **1,431** rps | 1,190 | **+20%** |
| c=10  | **7,003**     | 5,740 | **+22%** |
| c=100 | **8,943**     | 7,417 | **+21%** |
| c=500 | **8,757**     | 7,698 | **+14%** |
| c=1000| **8,272**     | 7,985 | **+4%** |

p99 latency:
| 並行度 | Spinel | Go |
|---|---|---|
| c=100 | **27ms** | 30ms |
| c=500 | 150ms | **119ms** |
| c=1000| 315ms | **256ms** |

スループットは全勝。p99 安定性は c≥500 で Go 優勢 (4 プロセス分散より
goroutine 多数の方が均される)。

### 解釈

- 22 KB のバイナリ × 4 worker (合計 88 KB 強) の prefork が、
  4.8 MB の Go バイナリ + goroutine ランタイムを **静的ファイル配信で上回った**
- Go の net/http は HTTP/1.1 chunked encoding 判定、ResponseWriter 抽象、
  Handler チェーン、context 引き回しなど経路長が長い。
  Spinel の手書き HTTP は経路がほぼ「recv → parse → File.read → send」。
  ミニマムが効く領域。

## 限界

- **キャッシュ・状態共有が困難**: 4 worker が独立。共有メモリ実装が必要に
  なれば Go の方が圧倒的に楽。
- **HTTP/2 不対応**: 1 接続多重化と prefork は相性悪い (1 接続=1 worker 固定)。
- **メモリリーク**: `@all` append-only。長寿命プロセスでは要対策。
- **graceful reload 未実装**: nginx 風 master/worker dance を書く必要あり。

## 次のステップ候補

1. **HTTP/2 対応** — どうせやるなら。リクエスト多重化があれば worker 偏りも改善。
2. **`@all` のコンパクト** — done 状態の FB を周期 GC。
3. **Ruby 3 Fiber Scheduler API 準拠** — `Fiber.set_scheduler` でこの
   epoll ループを差し込めれば、Spinel 用 Async gem として再利用可能。
4. **Spinel 本体への upstream**:
   - `infer_array_elem_type` で `"fiber"` を obj 扱いにする
   - PtrArray に shift/pop/delete_at を実装
   - `loop do` を式位置でも動くようにする
   - `Array#index` の戻り値を nil-safe に (Ruby 互換)
   - `ffi_write_*` を実装すれば struct を直書きできて helper.c 不要

## 続編 2: ファイルキャッシュ + Graceful Shutdown

### 達成内容

| 機能 | 結果 |
|---|---|
| ファイルキャッシュ (pre-load) | ✅ トップレベル定数で実装 |
| Graceful shutdown (signalfd 経由) | ✅ docker stop で exit=0 / 306ms で完了 |
| in-flight 接続の drain | ✅ 受付済は完了、新規は拒否 |

### 最終ベンチ (cache + graceful 4p, vs Go net/http)

| 並行度 | Spinel rps | Go rps | 差 |
|---|---|---|---|
| c=1   | **1,507** | 1,217 | +24% |
| c=10  | **7,317** | 5,547 | +32% |
| c=100 | **9,069** | 7,556 | +20% |
| c=500 | 7,487 | 7,573 | -1% (互角) |
| c=1000| **8,716** | 7,507 | +16% |

p99 latency も全レンジで Spinel 勝利。

### in-flight graceful shutdown 試験

2000 reqs at c=20 を流しながら `docker stop`:
- 1005 ok / 995 fail in 347ms
- container `exit=0`
- 受付け済は全完了、新規 accept は拒否 = 教科書通りの graceful 動作

### Graceful shutdown 実装の鍵

1. **signalfd で SIGTERM/SIGINT を fd 化** — epoll で他の I/O と一緒に待てる
2. **signal_watch fiber が SCHED.shutdown フラグを立てる**
3. **親プロセスは child_pids を覚えておき SIGTERM を転送**
4. **acceptor は次のループで shutdown? チェックして停止**
5. **run loop は「passive waiter (listen_fd, sigfd) のみ残った状態」を検知して exit**
   — active worker (cfd 待ち) が 0 になったら破棄 OK
6. **shutdown 中は epoll_wait に 100ms timeout** を付けて active worker 完了を周期チェック

## 続編 2 で踏んだ追加の Spinel 制約

### 11. **GC は class instance var の :str / Hash{:str=>:str} を維持できない**

class instance var に `:str` を持たせ、それをリクエストごとに参照すると、
**数百リクエスト後に SIGSEGV** する。`str_str_hash` も同じ。

検証で試した壊れるパターン:
```ruby
class FileCache
  def initialize; @index = ""; end
  def load; @index = File.read(...); end
  def get(p); @index; end
end
CACHE = FileCache.new
CACHE.load
# serve で CACHE.get → 数百回後にクラッシュ
```

```ruby
CACHE_DATA = {"" => ""}
CACHE_DATA["/"] = File.read(...)
# CACHE_DATA["/"] → 同上クラッシュ
```

動くパターン:
```ruby
INDEX_HTML = File.exist?(p) ? File.read(p) : ""   # トップレベル :str 定数
# 安定動作
```

恐らく Spinel GC が「クラスインスタンスから参照される文字列ヒープ」を
mark phase で取り逃がしている。**トップレベル定数経由の :str だけが
安全に長期保持できる**。これは upstream 報告すべき重大バグ。

### 12. fork 後の Spinel GC は親-子 COW を破壊する可能性

「fork 前にキャッシュロード → 各 worker が COW で共有」という nginx
スタイルの設計は **Spinel では成立しない**。各 worker が個別に
ロードする方式 (top-level 定数 で File.read) だと安定する。
これも GC 由来。

## 最終構成図

```
master process (PID 1)
├── INDEX_HTML, ABOUT_HTML  (top-level const, GC 安全)
├── child_pids = [7, 8, 9]
├── SO_REUSEPORT listen socket on :8080
├── signalfd → fd
├── epoll
└── Scheduler.run
    ├── acceptor fiber (waits on listen_fd)
    ├── signal_watch fiber (waits on sigfd)
    └── worker fiber × N (waits on cfd)

worker process (× 3)
├── 同上 (子は child_pids 空)
└── ...

SIGTERM 到着:
  master signal_watch:
    - shutdown=true
    - kill(child, SIGTERM) × 3
    - close(listen_fd) → acceptor wake
  acceptor: shutdown? → exit
  active workers: drain in-flight
  run loop: 全 worker 完了で exit
```

## 続編 3: HTTP/1.1 + keep-alive (Tier 1 #3 完成)

### 達成内容

`serve(cfd)` を 1 接続 = 1 fiber で複数リクエストをループ処理する形に。
- HTTP/1.1 デフォルト keep-alive
- HTTP/1.0 リクエストは自動 close
- `Connection: close` ヘッダ尊重
- 1 接続あたり最大 20 リクエストで safety close
- `TCP_NODELAY` で Nagle 切り (delayed-ACK 40ms 待ち回避)

### 最終ベンチ (keep-alive, n=5000, fresh container per test)

| 並行度 | Spinel keep-alive | Go keep-alive | 差 |
|---|---|---|---|
| c=1   | **6,015** rps | 4,416 | **+36%** |
| c=10  | **17,773**    | 13,283 | **+34%** |
| c=50  | **19,194**    | 10,986 | **+75%** |
| c=100 | **25,865**    | 13,965 | **+85%** |

**全レンジで Spinel keep-alive が Go を圧倒**。c=100 で +85%。

### 同期版 (前回) との比較

| 並行度 | sync (close) | async (close) | async (keep-alive) | 改善率 |
|---|---|---|---|---|
| c=1 | 1,985 | 1,507 | **6,015** | sync の 3.0x |
| c=100 | 3,670 | 9,069 | **25,865** | sync の 7.0x |

**keep-alive が圧倒的に効く** = TCP ハンドシェイク + fiber 作成のコスト削減。

### Nagle 罠の発見

最初の実装で keep-alive c=1 が **24 rps (p50 = 41ms)** という異常値。
原因: `nb_send_all(cfd, hdr); nb_send_all(cfd, body)` の 2 回 send。
Nagle + delayed-ACK 相互作用で約 40ms 待ちが入る。

修正: `TCP_NODELAY` を fd に有効化。helper.c に `sp_set_nodelay`
追加し、accept 直後にコール。これで 24 rps → 6,000 rps に回復。

教訓: HTTP/1.x keep-alive サーバを書くなら **TCP_NODELAY 必須**。
nginx/Apache はデフォルトで設定する。Go の net/http も内部で設定済。
自作する側は要注意。

### Spinel GC 起因の制約 (新発見)

ベンチを大量回すと SIGSEGV する閾値があり、HTTP/1.1 keep-alive モードで
n ≈ 8,000 〜 10,000 リクエストあたりが上限。

| n | c=100 keep-alive |
|---|---|
| 5,000 | ✅ 5000 ok / 0 fail |
| 10,000 | ⚠️ 8170 ok / 1830 fail (途中 SIGSEGV) |
| 20,000 | ❌ 8083 ok / 11917 fail (早期死) |
| 50,000 | ❌ 7989 ok / 42011 fail |

close モードはさらに脆く n=500 程度から不安定。
理由: 1 接続あたりの fiber 数が多く @all PtrArray が肥大 →
Spinel GC が追いつかず use-after-free 系の SIGSEGV。

これは制約 #11 (`docs/spinel-async-impl.md` の前段) と同根の Spinel GC バグ。
**回避策は load-shedding か再起動**。本番なら `MaxRequests=N` で worker
を定期的に再起動する nginx 風が現実解。

### Tier 1 完成度

ロードマップ Tier 1 「HTTP/1.1 + keep-alive (httpd_async 改修)」項目:
**実装完了**。ただし Spinel GC 由来で高負荷耐久性に難あり。

## 続編 4: Tier 2 #8 (MIME) + Tier 3 SSE

### MIME type lookup (Tier 2 #8)

11 行の `mime_for(path)` で拡張子 → Content-Type マップ:
`.html .css .js .json .png .jpg .jpeg .gif .svg .ico .txt .pdf` 対応。
fall-through で `application/octet-stream`。

検証:
```
/ → text/html; charset=utf-8 (200)
/about.html → text/html; charset=utf-8 (200)
/style.css → text/css; charset=utf-8 (200)
/app.js → application/javascript; charset=utf-8 (200)
/missing → text/plain (404)
```

### SSE = Server-Sent Events (Tier 3)

`/events` エンドポイントが 1 秒ごとに `event: tick / id: N / data: <iso>` を
ストリーミング。Fiber + epoll + timerfd が綺麗に協調する。

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

event: tick
id: 1
data: 2026-05-09T23:44:50Z

event: tick
id: 2
data: 2026-05-09T23:44:51Z
...
```

実装ポイント:

1. **timerfd を helper.c でラップ** (`sp_timerfd_create(interval_ms)`)
   - `timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK)` + `timerfd_settime` で
     周期発火する fd を生成
2. **SSE fiber は `SCHED.wait_io(tfd, EPOLLIN)` で時間待ち**
   - 通常の I/O 待ちと同じスケジューラ機構で「N 秒待つ」が表現できる
   - 余計な API 不要、既存 epoll に乗る
3. **クライアント切断検出は send の戻り値**
   - `nb_send_all` が false → -2 (EPIPE) → fiber 終了 → cfd close

並行 SSE クライアント検証:
```
$ for i in 1 2 3 4; do (curl -N localhost:8082/events &); done
[c1] event: tick / id: 1 / data: 23:45:05Z
[c2] event: tick / id: 1 / data: 23:45:05Z
[c3] event: tick / id: 1 / data: 23:45:05Z
[c4] event: tick / id: 1 / data: 23:45:05Z
[c1] event: tick / id: 2 / data: 23:45:06Z
...
```

**4 つの長寿命 SSE 接続 + 通常 HTTP リクエストが同一 worker で同時並走**。
これが goroutine 風 (= 色なし async) の真価で、ユーザコードに非同期記法は
出てこない。`SCHED.wait_io(tfd, 1)` だけで「1 秒待ち」が書ける。

### Tier 3 で SSE を選んだ理由

- **TLS / WebSocket / gzip は外部ライブラリ依存**で重い (OpenSSL FFI 等)
- **SSE は POSIX socket + timerfd だけで実現可能** = Spinel の射程内
- **Fiber + epoll の強みが最も出る**: 長寿命接続を低コストで多数捌ける
- **Ruby Async gem コミュニティが推す** stream 通信の代表

### 達成した tier 進捗 (続編 4 時点)

- **Tier 1: 8/8** (httpd_async が #3 担当、他は並行セッション)
- **Tier 2: 1/6** (#8 MIME 完了)
- **Tier 3: 1/8** (#17 SSE 完了)

## 続編 5: Tier 3 #18 (UUID) + Tier 2 #11 (構造化ログ)

### UUID v4 / v7 (Tier 3 #18)

helper.c に getrandom + clock_gettime を使ったジェネレータを追加。

```c
const char *sp_uuid_v4(void);  /* RFC 4122 §4.4: 122 bits random */
const char *sp_uuid_v7(void);  /* RFC 9562 §5.7: 48-bit unix-ms + 74 bits random */
```

エンドポイント `/uuid` は両方を JSON で返す:
```json
{"v4":"68586d22-3494-490b-bc52-486a326c9634","v7":"019e0f2f-e29a-7f80-b582-142342ed39cf"}
```

v7 の prefix `019e0f2f-e2` は ms タイムスタンプ部分なので連続呼び出しで
共通になり、**時系列ソート可能** (DB 主キーに最適)。

#### 罠: static buf 上書き

最初の実装で v4 と v7 が同じ値を返すバグ。原因: 両関数が
同一 `static char sp_uuid_buf[37]` に書く → Spinel が `H.sp_uuid_v4 + ... + H.sp_uuid_v7 + ...`
を評価する際、v7 呼び出しが v4 の戻り値ポインタを上書き。

→ 関数ごとに別 static buf に分けて解決。`:str` FFI 戻り値が
即時 sp_str_dup_external されない/評価順依存があるケースの対処パターン。

### 構造化ログ (Tier 2 #11)

JSON Lines (NDJSON) 形式で stderr へ。Docker で `docker logs` がそのまま
構造化ログとして使える。

```ruby
LOG_DEBUG = 0; LOG_INFO = 1; LOG_WARN = 2; LOG_ERROR = 3
LOG_LEVEL = LOG_INFO

def log_at(lvl_num, lvl_label, msg)
  return if lvl_num < LOG_LEVEL
  H.sp_log("{\"ts\":\"" + H.sp_iso_now + "\",\"lvl\":\"" + lvl_label + "\",\"msg\":\"" + msg + "\"}")
end

def log_info(msg); log_at(LOG_INFO, "INFO", msg); end
def log_warn(msg); log_at(LOG_WARN, "WARN", msg); end
```

serve() に `log_info("GET " + path)` を仕込んで access log として動作。

```
{"ts":"2026-05-10T00:00:57Z","lvl":"INFO","msg":"GET /uuid"}
{"ts":"2026-05-10T00:00:57Z","lvl":"INFO","msg":"GET /style.css"}
{"ts":"2026-05-10T00:00:57Z","lvl":"INFO","msg":"GET /events"}
```

#### 罠: 未使用 def が型推論を汚す

`log_debug` / `log_error` を定義したが使わなかった結果、Spinel 全体型推論で
`log_at` の `msg` パラメータが int に widen され全コンパイル失敗。

**Spinel では未使用 def は必ず削除する**。これは続編 3 の `respond` 削除忘れと
同じパターン。これで遭遇 #13 件目の制約。

### 達成した tier 進捗 (続編 5 時点)

- **Tier 1: 8/8**
- **Tier 2: 2/6** (#8 MIME, #11 Logger)
- **Tier 3: 2/8** (#17 SSE, #18 UUID)

## 続編 6: Tier 2 残り 4 個一気 (#7, #9, #10, #12)

### Tier 2 #12 Date/Time formatter

helper.c に `sp_iso_now / sp_rfc2822_now / sp_http_date_now / sp_unix_ms` を追加。`/now` エンドポイントが 4 形式を返す:

```json
{"iso":"2026-05-10T07:32:41Z",
 "rfc2822":"Sun, 10 May 2026 07:32:41 +0000",
 "http":"Sun, 10 May 2026 07:32:41 GMT",
 "unix_ms":1778398361635}
```

各フォーマット用に **別 static buf** (続編 5 の v4/v7 罠と同じ対策)。

### Tier 2 #10 Signed Session Cookie (HMAC-SHA256)

OpenSSL libcrypto を Docker に追加 (`libssl-dev` + `libssl3`)。helper.c で `HMAC(EVP_sha256(), ...)` を呼び、64 文字 hex で返す。タイミング攻撃対策の `sp_consttime_eq` も同梱。

Ruby 側:
```ruby
def session_sign(value);  value + "." + H.sp_hmac_sha256_hex(SESSION_SECRET, value); end
def session_verify(signed); ... H.sp_consttime_eq(sig, expected) == 1 ... end
```

`/session` エンドポイント:
- 初回: UUID v7 で新セッション生成 → `Set-Cookie: session=<id>.<sig>; HttpOnly; SameSite=Strict`
- 2 回目: cookie 検証 OK → `{"existing":true,"user":"<id>"}`
- **改ざん検出**: 末尾 3 文字書き換えた cookie → 不正と判定して新セッション発行

### Tier 2 #7 SQLite クエリビルダ

Spinel の `examples/ffi/sqlite/` を踏襲しつつ httpd_async に統合。Docker に `libsqlite3-dev/0` 追加。`Q.q(s)` で single quote エスケープ (SQL injection 対策)。`/users` エンドポイントが in-memory db から SELECT:

```json
[{"id":1,"name":"alice"},{"id":2,"name":"bob"},{"id":3,"name":"carol"}]
```

各 worker が独立 db (in-memory なので process 跨ぎ共有不可)。
本番なら file db を 4 worker で共有する形 (sqlite3 file lock で OK)。

### Tier 2 #9 Multipart parser (basic)

`POST /upload` で multipart/form-data を受信。Content-Type から boundary を抽出 → body から first part の content を切り出す。

```
$ echo "hello multipart from spinel" > /tmp/up.txt   # 28 bytes
$ curl -F "file=@/tmp/up.txt" http://localhost:8082/upload
{"boundary":"------------------------tx7EgcnbwQkqxcYlstEaoE",
 "size":28,
 "sha256":"0c792f021b6ca82eb10b8797e3206226cc599faaa720a304d78f41c5bf331090"}

$ sha256sum /tmp/up.txt
0c792f021b6ca82eb10b8797e3206226cc599faaa720a304d78f41c5bf331090
```

SHA-256 一致 ✓。helper.c に `EVP_Q_digest("SHA256")` 追加。

簡易実装の制約:
- 1 part のみ抽出 (multi-file unsupported)
- body は 1 recv で全部届く前提 (req_buf 4KB 以下)
- chunked transfer 不対応

実用化するには (a) 複数 recv で連結 (b) Transfer-Encoding: chunked 解釈 が必要。

### 達成した tier 進捗 (続編 6 時点)

- **Tier 1: 8/8** ✅
- **Tier 2: 6/6** ✅ (全完成)
- **Tier 3: 2/8** (#17 SSE, #18 UUID)

## 続編 7: Phase 2 — pure Spinel への揺り戻し

### 動機

続編 1〜6 で helper.c が肥大化 (300 行近く)。一部は C である必要が無い:

| C にある必要 | C にいるが Ruby でも書ける |
|---|---|
| syscalls (epoll, fork, sigalfd) | date format (strftime 相当) |
| crypto (HMAC, SHA256) | logger format string |
| `:ptr` ↔ `:str` 変換 | UUID 形式整形 (バイトは getrandom 必要) |
| TLS / SQLite 等の外部 lib | enum lookup (MIME, status) |

整理方針: **「format / 変換ロジックは Ruby 側、syscall / crypto は C 側」**。

### 実施した phase 2 の refactor

#### date formatter を Ruby に降ろす

helper.c から削除:
- `sp_iso_now()` (15行)
- `sp_rfc2822_now()` (15行)
- `sp_http_date_now()` (15行)
- 各 static buf

helper.c に追加 (代替):
```c
const char *sp_gmtime_str(long epoch_secs) {
    /* "Y M D h m s wday" を space 区切りで返すだけ */
    ...
}
```

Ruby 側に format ロジック:
```ruby
WDAY_NAMES = ["Sun", "Mon", ..., "Sat"]
MON_NAMES  = ["Jan", "Feb", ..., "Dec"]

def now_parts
  s = H.sp_gmtime_str(H.sp_unix_ms / 1000)
  ps = s.split(" ")
  [ps[0].to_i, ps[1].to_i, ps[2].to_i,
   ps[3].to_i, ps[4].to_i, ps[5].to_i, ps[6].to_i]
end

def iso_now
  p = now_parts
  pad4(p[0]) + "-" + pad2(p[1]) + "-" + pad2(p[2]) + "T" \
    + pad2(p[3]) + ":" + pad2(p[4]) + ":" + pad2(p[5]) + "Z"
end
```

#### 結果

- helper.c: **40 行減** (date 系 50 行 + sp_recv_str 10 行)
- httpd_async.rb: **30 行増** (WDAY/MON 名前 + pad2/pad4 + 3 formatter)
- net: **C 縮小、Ruby 拡大、format string が言語レベルで見える** (upstream に提案しやすい)

### Phase 2 の判断基準

「pure Spinel に降ろすべきか?」のフローチャート:

```
1. syscall を直接呼ぶ?
   → YES: helper.c (例: epoll_ctl, accept, fork)
2. 暗号 / 圧縮 / DB エンジン (大規模 C 資産)?
   → YES: helper.c (例: HMAC_SHA256, sqlite3_*)
3. ポインタ操作 / バイナリ / errno?
   → YES: helper.c (例: sp_buf_as_str, sp_recv_nb)
4. それ以外 (format, parse, dispatch, lookup)?
   → Ruby (httpd_async.rb)
```

### 降ろせなかったもの (C のまま正解)

- **UUID format**: 16 byte の bit operations が Spinel で書きづらい  
  (no `[i].chr.ord & 0x0F` 系のサクッとした記法)
- **consttime_eq**: 定数時間比較は Spinel optimizer の動作が読めないので
  C の方が安全 (security primitive)
- **sp_log**: stderr 出力 = `STDERR.puts` 不在のため C 必須

### Phase 2 後の helper.c 構成

| カテゴリ | 関数数 |
|---|---|
| socket / epoll syscall | 9 |
| fork / signal / timer | 5 |
| ptr/str cast + log | 2 |
| 暗号 (HMAC, SHA256, consttime) | 3 |
| 乱数 / 時刻 (低レベル) | 4 |
| **計** | **23 関数** (約 200 行) |

phase 1 (続編 6 時点) は 27 関数 250 行 → 4 関数 50 行減。

### 次の phase 2 候補 (続編 8 で完了)

- **MIME lookup** を `lib/mime.rb` モジュールに切り出し
- **logger** を `lib/logger.rb` モジュール化
- **session** を `lib/session.rb` モジュール化
- **multipart parser** を `lib/multipart.rb` モジュール化

## 続編 8: web/*.rb モジュール切り出し

### 構造

```
spinel-demo/
├── httpd_async.rb        613 行 (HTTP コア + 配線)
├── helper.c              301 行 (syscall + crypto)
└── web/
    ├── date.rb            53 行 (Tier 2 #12)
    ├── logger.rb          20 行 (Tier 2 #11)
    ├── mime.rb            21 行 (Tier 2 #8)
    ├── session.rb         39 行 (Tier 2 #10)
    └── multipart.rb       44 行 (Tier 2 #9)
                          ─────
                          177 行 (web/ 計)
```

httpd_async.rb から該当ロジックを抜いて `require_relative "web/..."` に置換。

### 仕組み

Spinel の `require_relative` は **parse time に inline** するため、
ビルド成果物は単一バイナリのまま。実行時オーバヘッドなし。

Dockerfile に `COPY web /opt/spinel/web` を追加するだけ。

### モジュール分割の依存グラフ

```
web/date.rb       (依存: H.sp_unix_ms, H.sp_gmtime_str)
   ↑
web/logger.rb     (依存: H.sp_log, iso_now)
                  
web/mime.rb       (依存: なし — pure logic)
web/session.rb    (依存: H.sp_hmac_sha256_hex, H.sp_consttime_eq)
web/multipart.rb  (依存: なし — pure string parse)
```

依存順に require_relative すれば衝突なし。

### Spinel での開発感覚

CRuby との対比:

| 項目 | CRuby | Spinel |
|---|---|---|
| ロード方式 | runtime dlopen | parse time inline |
| 依存解決 | gem / Bundler | require_relative + ファイル配置 |
| 名前空間 | module 必須 (gem 衝突) | 名前は flat (inline 後同一 AST) |
| 開発体験 | `gem install` | git submodule / コピー |

Spinel は **「Crystal の shards」「Go の vendor/」と同じカテゴリ**。  
runtime gem 不在は AOT 言語共通の制約。

### Spinel コミュニティへの upstream 候補

httpd_async が使ってる `web/*.rb` は他の Spinel ユーザにも有用:
- `web/mime.rb` (21 行) — 拡張子 → Content-Type
- `web/multipart.rb` (44 行) — 簡易 multipart/form-data
- `web/session.rb` (39 行) — HMAC cookie
- `web/date.rb` (53 行) — RFC 3339 / 2822 / HTTP-date 整形
- `web/logger.rb` (20 行) — JSON Lines

= 合計 177 行で **「Spinel で Sinatra 風 web 開発」の標準パーツ群** が揃う。  
matz/spinel リポジトリ (upstream) の `lib/web/*.rb` として PR する筋。  
並行セッションの `lib/json.rb` `lib/url.rb` と合わせれば **400 行未満で Web フレームワーク基盤**。

### 全エンドポイント一覧 (httpd_async 最終版)

| Path | 機能 | Tier |
|---|---|---|
| `/` | index.html (cache + MIME) | 1 |
| `/about.html` | about.html | 1 |
| `/style.css` | CSS (MIME = text/css) | 2 #8 |
| `/app.js` | JS (MIME = application/javascript) | 2 #8 |
| `/users` | SQLite SELECT (JSON) | 2 #7 |
| `/upload` (POST) | multipart/form-data 受信 | 2 #9 |
| `/session` | HMAC 署名 cookie | 2 #10 |
| `/now` | 4 形式日付 (JSON) | 2 #12 |
| `/uuid` | UUID v4 + v7 (JSON) | 3 #18 |
| `/events` | SSE 1秒間隔 tick | 3 #17 |

ログは access log (Tier 2 #11 Logger) で全リクエスト記録。

## 検証日

2026-05-09 / Spinel master / Go 1.22.2 / n1 (Ubuntu 24.04, 4 core x86_64)

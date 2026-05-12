# spinel-demo — Spinel で書いた async HTTP サーバ + Web ライブラリ群

[matz/spinel](https://github.com/matz/spinel) で Sinatra 相当の Web 開発を可能にする
最小ライブラリセット + 動作デモ。

`httpd_async.rb` (~600 行) + `web/*.rb` (11 モジュール ~250 行) + `helper.c` (~580 行) で
**4 worker prefork + Fiber + epoll + HTTP/1.1 keep-alive + WebSocket + SSE + TLS** を実現。
Go の `net/http` を全並行レベルで上回るスループットを単一バイナリで配信。

## TL;DR

| 項目 | 値 |
|---|---|
| Spinel 出力バイナリ | **22 KB** (libc/libssl/libcrypt/libz/libsqlite3 動的リンク) |
| Docker image | 約 83 MB (debian:bookworm-slim base) |
| ベンチ (c=100, keep-alive) | **25,865 rps** (Go: 13,965 rps、**+85%**) |
| Tier 進捗 | **Tier 1: 8/8 / Tier 2: 6/6 / Tier 3: 8/8** |

## 関連プロジェクト

- [gorin9/spnl-web](https://github.com/gorin9/spnl-web) — Web ライブラリ群 (本 demo で vendor 経由で使用)
- [gorin9/spinel-packer](https://github.com/gorin9/spinel-packer) — 依存管理 CLI (vendor / lock / pack)
- [matz/spinel](https://github.com/matz/spinel) — 本家 Spinel コンパイラ

## エコシステム実戦使用例

本 repo は **spinel-packer + spnl-web の実用デモ**:

```
Spinelfile         # use "gorin9/spnl-web", sha: "49cd5eb..."
Spinelfile.lock    # spinel-packer install / lock で生成、tree_sha256 で改ざん検出
.gitignore         # /vendor/ を ignore (ローカル生成、commit しない)
vendor/            # spinel-packer install で復元される (gitignore 対象)
  gorin9__spnl-web/
    .spnl-source   # 取得元・SHA 記録
    web/*.rb       # 11 modules
    README.md, LICENSE...
```

### clone 後の build フロー (利用者)

```sh
git clone https://github.com/gorin9/spinel-demo
cd spinel-demo
spinel-packer install      # Spinelfile.lock から vendor/ を厳密復元
spinel httpd_async.rb -o httpd_async
./httpd_async
```

Docker なら 1 コマンド (内部で `spinel-packer install` 実行):
```sh
docker build -f Dockerfile.async -t demo .
docker run -p 8082:8080 demo
```

### 依存更新フロー (メンテナ)

```sh
spinel-packer upgrade gorin9/spnl-web        # main の最新へ
# or
spinel-packer upgrade gorin9/spnl-web@v2.0   # 特定 tag へ

git diff Spinelfile Spinelfile.lock          # 変更確認
git commit -am "bump spnl-web"
```

### CI 検証
```sh
spinel-packer install   # lock 通り復元 (drift で exit 1)
spinel-packer check     # 念のため一致確認
```

## クイックスタート

```sh
docker build -f Dockerfile.async -t spinel-httpd:async .
docker run --rm -p 8082:8080 spinel-httpd:async
```

```sh
curl http://localhost:8082/uuid
# {"v4":"...","v7":"..."}

curl http://localhost:8082/now
# {"iso":"...","rfc2822":"...","http":"...","unix_ms":...}

curl http://localhost:8082/users
# [{"id":1,"name":"alice"},...]
```

## エンドポイント一覧

| Path | 機能 | Tier |
|---|---|---|
| `/` | index.html (cache + MIME) | 1 |
| `/about.html`, `/style.css`, `/app.js` | 静的ファイル | 1 / 2 #8 |
| `/users` | SQLite SELECT (JSON) | 2 #7 |
| `/upload` (POST) | multipart/form-data + SHA-256 | 2 #9 |
| `/session` | HMAC 署名 cookie ログイン | 2 #10 |
| `/now` | 4 形式の現在時刻 | 2 #12 |
| `/csrf`, `/csrf/verify?token=` | CSRF トークン発行 / 検証 | 3 #15 |
| `/bcrypt?p=X` | bcrypt hash + 自己検証 | 3 #14 |
| `/gz` | Content-Encoding: gzip 配信 | 3 #20 |
| `/ws` | WebSocket echo (RFC 6455) | 3 #16 |
| `/events` | SSE 1秒間隔 tick | 3 #17 |
| `/uuid` | UUID v4 + v7 | 3 #18 |
| `/smtp-demo` | SMTP client (localhost:25 への接続試行) | 3 #19 |
| `/tls-demo` | TLS init (PEM ファイル必要) | 3 #13 |

全リクエストは **JSON Lines** 形式の access log として stderr 出力 (Tier 2 #11)。

## ファイル構成

```
spinel-demo/
├── README.md              この文書
├── Dockerfile.async       build 定義 (Spinel async 版)
├── Dockerfile             同期版 (比較用)
├── Dockerfile.go          Go 比較用
├── Spinelfile             依存マニフェスト (現状: 依存無し)
├── httpd_async.rb         ~600 行 (HTTP コア + 配線)
├── httpd.rb               同期版 (~120 行)
├── httpd.go               Go 比較実装 (~10 行)
├── helper.c               ~580 行 (syscall + crypto + TLS + zlib + bcrypt)
├── bench.go               ベンチクライアント
├── www/                   配信コンテンツ (HTML / CSS / JS)
├── web/                   Web ライブラリ群 (~250 行 / 11 モジュール)
│   ├── scheduler.rb        Fiber + epoll の核
│   ├── date.rb             RFC 3339 / 2822 / HTTP date format
│   ├── logger.rb           JSON Lines 構造化ログ
│   ├── mime.rb             拡張子 → Content-Type
│   ├── session.rb          HMAC-SHA256 cookie session
│   ├── csrf.rb             CSRF トークン
│   ├── bcrypt.rb           bcrypt hash / verify
│   ├── multipart.rb        multipart/form-data 簡易 parser
│   ├── websocket.rb        RFC 6455 echo サーバ
│   ├── smtp.rb             SMTP client
│   └── tls.rb              TLS init (sketch)
└── docs/
    ├── spinel-httpd.md         同期版実装の記録
    ├── spinel-async-impl.md    async 版実装記録 (Spinel 制約 13 件含、全 8 編)
    └── concurrency-models.md   goroutine vs async/await vs Fiber 論
```

## アーキテクチャ

```
master process (PID 1)
├── INDEX_HTML, ABOUT_HTML, STYLE_CSS, APP_JS  (top-level :str 定数, GC 安全)
├── SQLite in-memory db (per process)
├── child_pids = [pid7, pid8, pid9]
├── SO_REUSEPORT listen socket on :8080
├── signalfd (SIGTERM 受信用)
├── epoll
└── Scheduler.run
    ├── acceptor fiber   (waits on listen_fd)
    ├── signal_watch fiber (waits on sigfd)
    └── worker fiber × N (waits on cfd)

worker process × 3 (同上、child_pids 空)
```

SIGTERM 到着 (`docker stop`) → master が children に SIGTERM 転送 →
acceptor 停止 → active worker は in-flight を drain → exit 0 (約 300 ms)。

## ベンチマーク

n1 (4 core x86_64, Ubuntu 24.04) で測定。

### HTTP/1.1 keep-alive (n=5000)

| 並行度 | Spinel ka | Go ka | 差 |
|---|---|---|---|
| c=1   | 5,881 | 6,124 | -4% (互角) |
| c=10  | **17,773** | 10,986 | +62% |
| c=50  | **19,706** | 17,704 | +11% |
| c=100 | **25,865** | 13,965 | **+85%** |

### Connection: close (n=10000)

| 並行度 | Spinel async 4p | Go net/http | 差 |
|---|---|---|---|
| c=1   | **1,431** | 1,190 | +20% |
| c=10  | **7,003**  | 5,740 | +22% |
| c=100 | **8,943**  | 7,417 | +21% |
| c=500 | **8,757**  | 7,698 | +14% |
| c=1000| **8,272**  | 7,985 | +4% |

詳細: `docs/spinel-async-impl.md`

## なぜ Spinel か

| 項目 | 値 |
|---|---|
| 単一バイナリ配布 | 22 KB |
| ランタイム依存 | libc + 動的リンク群のみ |
| 起動時間 | ~50 ms (Docker 込み ~500 ms) |
| メモリ | 31 MB / worker (4 worker = 124 MB) |
| ビルド時間 (.rb → bin) | 0.5 s |

Crystal / Go と同じ **「AOT 単一バイナリ」** カテゴリだが、**Ruby 構文** で書ける。
gem は不在 (parse time inline で代替、Cargo / shards 風)。
依存解決には [gorin9/spinel-packer](https://github.com/gorin9/spinel-packer) を併用可能。

## Spinel の制約 (発見 13 件)

実装で踏んだ罠。Spinel master 時点。詳細は `docs/spinel-async-impl.md`。

1. **stdio/unistd 系 `ffi_func` 再宣言不可** → `<sys/socket.h>` 系のみ使う
2. **`:ptr` → `:str` 変換無し** → helper.c に cast 関数
3. **struct 引数を直接呼べない** → helper.c でラップ
4. **errno が読めない** → helper で -1/-2 区別
5. **配列要素型に Fiber 不可** (int_array に落ちる) → `class FB` でラップ
6. **PtrArray は shift/pop/delete_at 未実装** → int index で参照
7. **`Fiber.new(&block)` ブロック転送不可** → `Fiber.new { method_call }` の形
8. **`while true` (定数) は式位置でループしない** → `forever = true` 変数化
9. **`loop do ... end` も式位置で no-op** → `while` 代替
10. **`arr.index(v)` は -1 を返す** (nil ではない) → `if wi >= 0` 判定
11. **class instance var の :str / Hash{:str=>:str} を GC が誤認** (数百req後 SIGSEGV) → トップレベル定数で持つ
12. **static buf 共有の `:str` 戻り評価順依存** → 関数ごとに別 buf
13. **未使用 def が型推論を汚染** (param が int に widen) → 必ず削除 or 呼び出しを追加

## Spinel 本体への upstream 候補

直すと書きやすくなる順:

1. `infer_array_elem_type` で `"fiber"` を `obj_` 扱い → `FB` ラッパー不要
2. `PtrArray` に `shift / pop / delete_at` 実装 → `@all` append-only 不要
3. `while true` / `loop do` を式位置でも正しくループ → Fiber.new ブロックで自然
4. `arr.index` が見つからない時 nil 返却 → Ruby らしい記法
5. `ffi_write_*` 実装 → struct 直書きが可能、helper.c 激減
6. 未使用 def の param 型を int に widen しないように → 罠 #13 の根治
7. class instance var の :str 保持を GC が追跡 → 罠 #11 の根治

## 並行モデルの考察

詳細: `docs/concurrency-models.md`

- **goroutine (ランタイム持ち) は async/await より人間に優しい**。色付き関数問題が無い。
  Java virtual thread (2023) や Ruby Fiber Scheduler (2020) も同路線。
- ただし goroutine 風は **言語＋ランタイム一体設計** が必要。後付けは非現実的。
- **Spinel に goroutine 風は載せるべきでない**。22 KB の売りが消える。
- **Spinel の落としどころは「Fiber + epoll」** = 色なし async/await。
- **CPU 並列が要るなら `fork() + SO_REUSEPORT`** (nginx 方式)。

→ Spinel は **mini-nginx** の射程。Caddy にはなれない (goroutine 不在のため)。

## デプロイ

### Docker (推奨)
```sh
docker build -f Dockerfile.async -t spinel-httpd:async .
docker run -d --name httpd -p 80:8080 spinel-httpd:async
```

### Bare metal
```sh
git clone https://github.com/matz/spinel && (cd spinel && make)
cc -O2 -c helper.c -o helper.o && ar rcs libspinelhelper.a helper.o
./spinel httpd_async.rb -o httpd_async
./httpd_async
```

依存パッケージ (Debian):
- ビルド: `libssl-dev libsqlite3-dev libcrypt-dev zlib1g-dev build-essential`
- 実行: `libssl3 libsqlite3-0 libcrypt1 zlib1g`

### Graceful shutdown
```sh
docker stop --timeout=10 httpd
# 306 ms で exit 0、in-flight 接続は drain される
```

## 開発ガイド

### Spinel 用 Ruby を書くコツ

- **未使用 def は削除** (型推論を汚染する)
- **トップレベル定数は GC 安全** (class ivar の :str / Hash 保持は数百req後 SIGSEGV)
- **`arr.index(v)` の戻り値は `>= 0` で判定** (nil ではなく -1)
- **`while forever` と書く** (`while true` は式位置で no-op)
- **`Fiber.new { method_call }` で wrap** (`&block` 転送不可)

詳細は `docs/spinel-async-impl.md` の制約一覧を参照。

## ライセンス

MIT

## 検証環境

- 2026-05-12
- n1: Ubuntu 24.04, Linux 6.14, x86_64 4 core
- Spinel: master (1276 commits 時点)
- Go: 1.22.2 (比較用)
- Docker base: `ruby:3.3-slim` (builder), `debian:bookworm-slim` (runtime)

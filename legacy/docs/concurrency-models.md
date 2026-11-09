# 並行モデル比較: goroutine / async-await / Fiber + epoll

Spinel httpd を c=100 で殺された後の、「次は何を載せるか」の検討メモ。
goroutine 風 vs epoll 風 vs async/await の本音比較。

## 結論先出し

1. **goroutine は async/await より人間に優しい。** 「色付き関数問題」が
   無いだけで保守性は段違い。これはユーザーの直感に同意。
2. **ただし goroutine は言語＋ランタイム一体設計が前提。** Java が
   Project Loom (virtual thread) で実現するのに 21 年かかった事実が
   重い。Spinel に後付けは現実的でない。
3. **Spinel の出口は「Fiber + epoll」一択。** これは事実上
   「色なし async/await」。Ruby 3 の Fiber Scheduler API が同じ路線。
   Go には届かないが、async/await よりは書きやすい。

## 三つの並行モデル

### A. async/await (Rust, JS, Python, C#, Swift)

```rust
async fn handle(req: Request) -> Response { ... }
```

| ✓ | ✗ |
|---|---|
| 中断点が明示的 (`await`) → 何処でロックを取るか見える | **色付き関数問題**: `async fn` を呼べるのは `async fn` だけ。コードベース全体に async が伝播 |
| シングルスレッドでも動く (JS) | 同期 API と非同期 API が二重化 (`File::read` と `tokio::fs::read`) |
| コンパイラに状態機械を生成させる → ゼロコスト | スタックトレースが分断されがち |
| 構造化並行 (Rust の structured concurrency) で cancel が綺麗 | エコシステム分裂 (tokio / async-std / smol) |

### B. goroutine / virtual thread (Go, Java 21+, Erlang/BEAM)

```go
go handle(req)   // 普通の関数呼び出しに `go` 付けるだけ
```

| ✓ | ✗ |
|---|---|
| **色なし**。同期コードがそのまま並行コードになる | 中断点が見えない (preempt は GC safepoint or ループバックエッジ) |
| スタックトレースが綺麗（一本のコールスタック） | スタック成長の隠れコスト (Go は分割スタック) |
| ランタイムが M:N スケジュール → CPU 並列も透明 | **goroutine リーク** が普通に起こる (cancel を context.Context で手で配る) |
| 言語標準 → エコシステム分裂無し | データ競合は別途同期プリミティブで防ぐ必要 |

### C. Fiber + epoll (Ruby 3 Fiber Scheduler, lua coroutines, mruby)

```ruby
Fiber.schedule { handle(req) }   # 協調的
```

| ✓ | ✗ |
|---|---|
| **色なし** (yield が暗黙化される — Ruby 3 Fiber Scheduler) | 単一スレッド前提 → CPU 並列性は別途 (process fork or pthread) |
| ランタイム改造が小さい (epoll/kqueue ラッパで足りる) | preempt 無し → `while true; end` で止まる |
| 同期 API と非同期 API を統一できる (Ruby Async gem) | スケジューラの実装次第で挙動がブレる |

## 個人的判定: goroutine > Fiber + epoll > async/await

### なぜ goroutine が最強か

「**色付き関数問題**」が決定的。async/await 系言語では、
ライブラリ関数を呼ぶたびに「これは async ?」を確認する作業が
入る。同じことをする関数が `read` と `read_async` で二つあって
シグネチャが違う。これは認知負荷の継続的な漏出で、
コードベースが大きくなるほど効いてくる。

goroutine は「関数は関数」。`io.Read(r, buf)` がブロックしようが
しまいが、呼び出し側は気にしない。ランタイムが裏で IO を
hook して goroutine をブロック→他に切り替え→IO 完了で復帰、を
やってくれる。**プログラマが並行性を意識する量が桁で違う**。

JavaScript の「Promise hell → async/await で改善」の歴史は、
async/await が「Promise よりはマシ」だと示しただけで、
goroutine と比べて優位とは別問題。

### なぜ「ランタイム持ち」が後付けで難しいか

goroutine 風は以下を要求する:

1. **軽量スタック** (Go: 2KB から開始、必要なら成長)
2. **M:N スケジューラ** (M OS スレッド ↔ N goroutine)
3. **preempt** (Go 1.14+ はシグナル割り込み)
4. **IO の透明な hook** (ネットワーク syscall を全て netpoll 経由に)
5. **GC との連携** (goroutine スタックを GC が走査)

これを言語仕様＋ランタイムで一体設計したのが Go と Erlang。
Java は Project Loom で 2002 年構想 → 2023 年正式採用。
**21 年かかった**。後付けの困難さの目安。

Rust が「言語に goroutine を入れない」と決めたのは技術判断として
正しい。所有権モデルとランタイム前提が衝突するから。
代わりに async/await + tokio で「ランタイムを選べる」設計にした。
これは Rust の "no runtime" 哲学と整合。

### Spinel の場合

Spinel は AOT で **「ランタイム透明性 + 22 KB バイナリ」** を売りにしている。
ここに goroutine 風ランタイムを載せると:

- スケジューラ + epoll ループ + preempt → **+数 MB**
- 一気に Go と同じ重さ。差別化が消える。
- Spinel の「軽さ」設計に反する。

→ Spinel が goroutine 風を採るのは合理的でない。

### Spinel の現実解: Fiber + epoll

Spinel は **既に Fiber を持っている**。
これは協調的並行の単位 (yield/resume) としては goroutine の半分。

足りないのは:

1. **epoll/kqueue ラッパ** (FFI で書ける、~200 行)
2. **Fiber スケジューラ** (Ready キュー + epoll_wait ループ)
3. **socket I/O が暗黙に Fiber.yield する仕組み** — これが核心。
   Ruby 3 の Fiber Scheduler API は、ブロック系 syscall 時に
   登録済みスケジューラに制御を渡す。Spinel もこれに倣えば
   「色なし」の async が実現できる。

これは事実上「ランタイム持ち async/await」。
async/await 言語と比べて:
- 色なし ✓
- ライブラリ二重化なし ✓
- 同期コードがそのまま並行コードになる ✓
- ただし CPU 並列はない (シングルスレッド前提)

Go と比べて:
- CPU 並列なし ✗
- preempt なし → `while` ループで詰む ✗
- でもエッジ/サイドカー用途なら十分

## 歴史的視点

- 1986: Erlang (BEAM 軽量プロセス) — goroutine の元祖
- 2009: Go 1.0 — Erlang のアイデアを「普通の言語」に持ち込んだ
- 2012: C# async/await — 関数色付け路線を確立
- 2017: Rust async/await stabilize — 同路線
- 2020: Ruby 3.0 Fiber Scheduler — 「色なし async」路線
- 2023: Java 21 virtual thread — goroutine が JVM 標準入り

**「色付け vs 色なし」の決着は静かに「色なし」優勢で進んでいる。**
Java の virtual thread 採用、Python の subinterpreter 強化、
Ruby の Fiber Scheduler、すべて「同期コードを並行に動かす」路線。
async/await は中間解として歴史的役割を終えつつある、というのが私の見立て。

ただし async/await が「悪い」ではなく、「ランタイム持ちがコスト的に許容される時代になった」
というのが実態。Rust のように「ランタイム持ちたくない」言語では今でも async/await が正解。

## Spinel への提案

優先度順:

1. **Fiber Scheduler API 実装** — epoll/kqueue ラッパ + accept/recv/send/read/write を Fiber.yield 可にする。Ruby 3 の API シグネチャを真似ればコミュニティ資産が流用できる。
2. **process fork による CPU 並列** — `fork()` + SO_REUSEPORT で複数プロセスが同じポートを listen。nginx 方式。Caddy ではない (後述)。
3. **goroutine 風は採らない** — Spinel の軽量設計に反する。

---

# 補足: prefork (SO_REUSEPORT) の欠点と Caddy/nginx の選択

## prefork の欠点

| # | 欠点 | 影響 |
|---|---|---|
| 1 | **状態共有が困難** | キャッシュ・rate limit・メトリクスが各プロセスに重複。共有メモリ or 外部ストアが必要 |
| 2 | **コネクション偏り** | SO_REUSEPORT は 4-tuple ハッシュ。長寿命接続が偏ると不均衡 |
| 3 | **HTTP/2 と相性悪い** | 1接続=1ワーカー固定 → そのワーカーが詰まると client 側全 req 遅延 |
| 4 | **graceful reload が地獄** | master/worker dance 自前実装。Go なら `Server.Shutdown` 一行 |
| 5 | **GC の COW 破壊** | Ruby/Python/Node の GC は mark bit 書き込み → fork の COW が壊れて memory 膨張 |
| 6 | **TLS セッションキャッシュ分散** | session ticket key 共有が必要 |
| 7 | **オブザーバビリティが面倒** | メトリクス集約に IPC が要る |
| 8 | **メモリフットプリント** | 各 worker 独立ヒープ × N |

逆に利点: プロセス分離（1個落ちても他生存）、実装単純、preempt 不要、OS スケジューラに任せられる。

## Caddy はどうしてる？ → **prefork しない**

Caddy = Go 製。**シングルプロセス・マルチスレッド・goroutine 無数**。

```
Caddy (1 プロセス)
├── OS thread × GOMAXPROCS (=4)
└── goroutine × 数千  (1 接続 = 1 goroutine)
        ↓ netpoll (epoll 抽象)
       カーネル
```

- `GOMAXPROCS=N` で N 個の OS スレッド使用 → CPU 並列
- `net` パッケージが内部 netpoll、goroutine が透明にブロック
- キャッシュ・状態は全部プロセス内で `sync.Mutex`/`atomic` で共有
- graceful reload は `http.Server.Shutdown` 一発

**Caddy が prefork しないのは Go の goroutine ランタイムが prefork の欠点を全部回避できるから。**

## nginx は？ → **prefork**

- master + N worker プロセス
- 各 worker は **シングルスレッド** + epoll で大量接続を非同期処理 (callback ベース)
- 共有メモリ (slab allocator) でキャッシュ・統計を共有
- TLS session ticket key を全 worker で共有

**nginx が prefork する理由**: C にはランタイムスケジューラが無いから。Spinel と同じ事情。

## サーバ別の戦略表

| サーバー | プロセス | スレッド/proc | I/O | CPU 並列 |
|---|---|---|---|---|
| **Caddy** | 1 | GOMAXPROCS | netpoll | goroutine + thread |
| **nginx** | master + N worker | 1 | epoll callback | プロセス並列 |
| **Apache event MPM** | master + N worker | 多 | epoll + thread | 両方 |
| **Unicorn (Ruby)** | master + N worker | 1 | blocking | プロセス並列 (1接続専有) |
| **Puma (Ruby)** | master + N worker | M | blocking | プロセス×スレッド |

**パターン整理**:
- **goroutine ランタイム持ち言語** → シングルプロセスで OK (Caddy)
- **ランタイム持たない言語** → prefork + 各 worker 非同期 (nginx)
- **thread 持つ言語** → prefork + thread (Apache, Puma)

## Spinel に当てはめると

| 戦略 | 評価 |
|---|---|
| Fiber + epoll **シングル**プロセス | I/O 並行 OK、CPU 並列なし。c=100 の I/O bound では十分 |
| **prefork + Fiber + epoll** = nginx 方式 | CPU 並列も取れるが上記欠点 8 個を背負う |
| goroutine 風ランタイム自作 | 22KB の売りが消える、Spinel の軽量設計に反する |

**Spinel の落としどころ**: **Caddy にはなれない**（goroutine が無いから）。
**「Ruby で書ける mini-nginx」** にはなれる。それがこの言語の射程。

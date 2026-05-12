# Spinel で簡易 HTTP サーバーを書く

matz の Ruby AOT コンパイラ [matz/spinel](https://github.com/matz/spinel)
で `python -m http.server` 相当の静的ファイルサーバーを書き、Go と
比較した記録。

## TL;DR

- 22 KB の単一バイナリで HTTP/1.0 が動く。依存は `libc.so.6` のみ。
- 低並行 (c=1〜10) では **Spinel の方が Go より速い**。
- 高並行 (c=100) では **Spinel の p99 が 1 秒に爆発**（シングルスレッド）。
- メモリは Go の方が小さい (11 MB vs 31 MB) — Spinel ランタイムが
  bigint/regexp テーブルを抱えるため。

## 構成

```
spinel-demo/
├── Dockerfile        Spinel 版マルチステージビルド
├── Dockerfile.go     Go 版（比較用）
├── httpd.rb          本体（Spinel）
├── helper.c          12 行の FFI ブリッジ
├── httpd.go          比較用 Go 実装
├── bench.go          逐次ベンチ用クライアント
└── www/              配信コンテンツ
```

## 設計上の障害と回避策

### 1. Spinel は socket を持たない → libc を FFI で直叩き

`socket / bind / listen / accept / send / close / getaddrinfo` を
すべて `ffi_func` で宣言。`libc` は常時リンクされるので
`ffi_lib` 不要。

### 2. `sp_runtime.h` が `stdio.h`/`unistd.h` を include 済 → 衝突

Spinel ランタイムが既に `stdio.h`/`stdlib.h`/`string.h`/`unistd.h` を
include しているため、`write/read/fdopen/fgets/fflush/fclose/...` を
`ffi_func` で再宣言すると C コンパイラが型衝突で落ちる。

→ **`<sys/socket.h>`/`<netdb.h>` 系の関数だけ使う**。
これらは pre-include されていないので自由に宣言できる。
`write` は `send` に、stdio FILE* 系は使わない。

### 3. `:ptr` バッファを Ruby 文字列に変換できない

Spinel の FFI は `ffi_read_u32 / ffi_read_i32 / ffi_read_ptr` のみ。
**バッファの中身を文字列として取り出す機能が無い**。

→ 12 行の `helper.c` を書いて回避：

```c
// helper.c
#include <sys/socket.h>
#include <stddef.h>

const char *sp_recv_str(int fd, void *buf, size_t cap) {
    if (cap == 0) return (const char *)0;
    ssize_t n = recv(fd, buf, cap - 1, 0);
    if (n < 0) return (const char *)0;
    ((char *)buf)[n] = '\0';
    return (const char *)buf;
}
```

`ffi_lib "spinelhelper" + ffi_cflags "-L..."` で静的リンク。

### 4. `sockaddr_in` を手で組めない (`ffi_write_*` 未実装)

`bind()` には初期化済みの `struct sockaddr_in` が必要だが、
Spinel の `ffi_buffer` は読み取り専用 (`ffi_read_*` のみ)、
書き込み手段がない。

→ **`getaddrinfo` に作らせる**。`"0.0.0.0"`, `"8080"` を渡せば
カーネル側で初期化済みの `sockaddr` を返してくれる。
Linux/glibc の `struct addrinfo` レイアウト
(`ai_addrlen@16, ai_addr@24`) を `ffi_read_u32 / ffi_read_ptr` で
読み出して `bind` に渡す。

### 5. SIGPIPE で死ぬ

クライアントが切断した socket に `send` すると SIGPIPE → プロセス終了。
ベンチの最初の試行で全 5000 リクエスト失敗の原因がこれだった。

→ `send(fd, buf, len, MSG_NOSIGNAL)` (`MSG_NOSIGNAL = 16384`)
を渡すことでシグナル発生を抑止。`signal()` でハンドラ登録する手も
あるが、`SIG_IGN`（マジックポインタ値 1）が Spinel FFI から
構築できないので不可。

## ベンチ結果 (n1: 4 core x86_64, Linux 6.14)

865 B の `index.html` を配信。

### 静的指標

| | Spinel | Go |
|---|---|---|
| バイナリ | **22 KB** | 4.8 MB |
| 依存 | libc.so.6 | libc.so.6 |
| イメージ | 75 MB | 80 MB |
| RSS | 31 MB | **11 MB** |
| 起動 | 578 ms | 524 ms |
| ビルド (httpd → bin) | **0.5 s** | ~5 s |

### スループット

| 並行度 | Spinel rps | Go rps |
|---|---|---|
| c=1   | **1,559** | 1,257 |
| c=10  | **6,511** | 5,627 |
| c=100 | 4,457 | **7,171** |

### レイテンシ

| 並行度 | Spinel p50/p99/max | Go p50/p99/max |
|---|---|---|
| c=1   | **574µs / 1.84ms / 4ms** | 740µs / 2.05ms / 7ms |
| c=10  | **1.42ms / 3.51ms / 7ms** | 1.64ms / 4.33ms / 12ms |
| c=100 | 2.0ms / **1,010ms / 2,243ms** | 12.9ms / 30.9ms / 49ms |

### 解釈

- **低並行は Spinel が勝つ。** AOT で関数呼び出し直叩き、
  HTTP パーサ等が無いミニマム実装。Go の `net/http` は
  goroutine スケジュール + chunked エンコード判定など
  経路長が長い。
- **高並行は Go の圧勝。** Spinel はシングルスレッド逐次 accept
  なので 100 接続が直列化され p99 が 1 秒超。Go は 4 コアで
  goroutine が並列化、p99 ≈ 30ms。
- **メモリは Go。** Spinel の 31 MB は bigint/regexp/GC ヒープの
  初期確保。

## 適性

| 用途 | 適性 |
|---|---|
| エッジ / サイドカー / 単発バッチ | **Spinel** (低並行・小バイナリ) |
| 一般 Web アプリ (c≥100, p99 重要) | **Go** |
| CLI ツール配布 | **Spinel** (22 KB で配布が楽) |

## 次の手

1. **Fiber + epoll** で non-blocking 化。シングルスレッドのまま
   c=100 の tail を潰せる可能性。要 epoll FFI と Fiber スケジューラ。
2. **MIME type 判定**: 現状 `text/html` 固定。`File.extname` で分岐。
3. **Range / If-Modified-Since**: 静的サーバーとしての完全度を上げる。
4. **DSL レイヤ**: `get "/users/:id" do ... end` 風 Sinatra ライク。

## 検証日

2026-05-09 / Spinel master (1276 commits 時点) / Go 1.22.2

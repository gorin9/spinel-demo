# spinel-demo

A reproducible Ruby → generated views/routes/models → Spinel HTTP application.
The baseline uses standard Thread/socket scheduling and official spin dependencies.
The May Fiber/epoll experiment is archived under legacy/; its size and speed claims
are historical and are not claims about this version.

## Quick start

Install CRuby 3.1+, git, a C compiler, make, OpenSSL/libcrypt development libraries,
and Spinel 2026.10.25. Ubuntu/Debian build dependencies are build-essential,
libssl-dev, libcrypt-dev and pkg-config; SQLite development files are also needed
when building the reference master compiler's SQLite package.

```sh
bundle install
ruby scripts/bootstrap.rb       # restore pinned CRuby generation tools
ruby scripts/generate.rb        # ERB 2.2.3, validated routes, model and RBS
spin fetch
spin vendor
SPIN_OFFLINE=1 spin build demo
# A local HTTP cookie demonstration; do not use Secure=0 over a public network.
export SPNL_SESSION_SECRET="$(ruby -rsecurerandom -e 'print SecureRandom.hex(32)')"
SPNL_COOKIE_SECURE=0 ./build/bin/demo
```

Open http://127.0.0.1:8080/. HOST and PORT configure the listener; SPNL_PUBLIC
(default `public`, relative to the working directory) supplies static assets.
No secrets, database or private uploads belong in public/.

spin.toml/spin.lock pin runtime source commits. tools.lock.json pins the CRuby
build tools. Bootstrap refuses a modified tool checkout instead of overwriting it.
For development, sibling checkouts can be selected with `spin add NAME --path ...`;
restore the committed manifest/lock before shipping. Do not commit that local override.

## Endpoints and behavior

| Endpoint | Behavior |
|---|---|
| /health | readiness JSON |
| /bench | fixed preloaded 17-byte text response |
| /, /index.html, /about.html, /style.css, /app.js | cached public assets |
| /users, /site/, /site/users | seeded users and generated views/routes/models |
| /uuid | standard UUIDv4 and RFC 9562 UUIDv7 over SecureRandom |
| /now | standard Time formats |
| /session | versioned HMAC-signed cookie; requires SPNL_SESSION_SECRET |
| /csrf, /csrf/verify?token=... | session-bound signed double-submit demonstration |
| /upload (POST) | bounded multiple-part parser, including binary content |
| /ws | validated WebSocket upgrade and text/binary echo, ping/pong, fragmentation |
| /events | finite three-tick SSE demonstration |
| /gz | gzip-compressed index |
| /bcrypt?p=... | bounded password hash/self-verification demonstration |

This is a bounded HTTP subset: responses close the connection, request headers are
limited to 16 KiB and bodies to 1 MiB, duplicate headers/Transfer-Encoding/pipelining
are rejected. Connections have a five-second handler timeout and a 128-slot limit.
WebSocket and SSE demos share that timeout. TLS termination and authenticated SMTP
policy are separate opt-in spnl-web APIs; no endpoint sends email or loads a secret key
at startup. The old /smtp-demo and /tls-demo sketches are not presented as working
production features. A reverse proxy may terminate HTTPS and normalize input framing.

## SQLite variant

Release 2026.10.25 has no bundled SQLite3 extension. For the pinned reference master
60c0273261415d2b5edd6480667a705a68addbd2, build the compiler with SQLite headers/library
installed, then:

```sh
spinel $(spin flags) examples/demo_db.rb -o build/bin/demo-db
SPNL_DATABASE=demo.sqlite3 ./build/bin/demo-db
```

This uses the standard SQLite3 package through the schema adapter's synchronized
connection. The generated model performs real bound queries; source data is persistent
and outside public/. The package may report deferred refusals for its unused dynamic
aggregate/extension-loading APIs; those APIs are outside the tested contract. CRUD,
rollback, threaded /users and shutdown are tested on the supported paths.
The standard CGI form codec avoids a pinned-master URI/SQLite composition issue;
see spnl-utils/docs/upstream-compatibility.md.

## Verification and deployment

```sh
rake test
spin test
python3 test/network_smoke.py
spin pack demo --out build/deploy
make -C build/deploy -j2
DEMO_COMMAND=./build/deploy/demo python3 test/network_smoke.py
```

The network test checks actual status/body, sessions and bound CSRF, HEAD/405, fragmented
HTTP, 40 concurrent requests, WebSocket control/fragment/binary frames, SSE and a clean
SIGTERM exit. CI runs the release and reference-master matrices, regenerates checked-in
output, builds offline from vendor, checks the SQLite variant, exports/rebuilds the C
pack, and builds/smokes the Docker image. Generated source uses a pinned standard ERB
version so regeneration does not silently follow the host Ruby's default ERB version.

```sh
docker build -t spinel-demo .
docker run --rm -p 127.0.0.1:8080:8080 -e SPNL_SESSION_SECRET spinel-demo
```

Dockerfile.async is an alias for Dockerfile. Runtime source refs and compiler commit
are pinned; base-image tags/apt repositories are not digest-pinned, so no bit-for-bit
reproducibility is claimed. Runtime needs libc, libm, libssl/libcrypto and libcrypt.
C packs contain build sources, not static application assets: copy public/ and configure
SPNL_PUBLIC when deploying them elsewhere. Images run as an unprivileged user.

## Performance

See [measurement conditions and results](docs/benchmark.md) and the JSON raw evidence.
Go 1.27.3 and Spinel 2026.10.25 both serve the same preloaded body and close connections,
with the same server CPU budget. This local measurement does not support the old
"faster than Go at every concurrency" claim.

```sh
go build -o build/bench bench.go
go build -o build/go-server httpd.go
python3 scripts/benchmark.py --spinel ./build/bin/demo --go ./build/go-server --client ./build/bench
```

MIT licensed. Version 0.2.0 is an unreleased modernization branch. See CHANGELOG.md
and docs/concurrency-models.md. Historical notes remain under legacy/ and are marked.

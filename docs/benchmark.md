# Local benchmark — 2026-11-09

The same 17-byte preloaded body, status 200, Connection: close. Server processes are
restricted to the same two CPUs; the client uses two other CPUs. Spinel uses three
OS workers including its acceptor; Go uses GOMAXPROCS=2. Each cell is the median
of three runs of 5,000 requests, after warmup. HTTP status, body and read errors
are checked. Spinel release 2026.10.25 was exported with spin pack and built with
GCC 12.2.0 -O2; server and client Go binaries use Go 1.27.3. Raw evidence is in
benchmark-results-2026-11-09.json.

| Concurrency | Spinel requests/s | Go requests/s |
|---|---:|---:|
| 1 | 11,703 | 12,254 |
| 10 | 23,383 | 25,303 |
| 50 | 26,830 | 34,933 |

These are local measurements of a bounded reference server, not a general language
ranking or production capacity estimate. net/http supports a much larger HTTP surface.
The prototype claim that Spinel wins at every concurrency level is withdrawn.
Container base tags and OS packages are not pinned by digest; no bit-for-bit build
reproducibility is claimed. Re-run the script on the deployment hardware.

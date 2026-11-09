# Current concurrency model

The May experiment predates Spinel's M:N Thread runtime. It is archived under
legacy/docs. The current server uses TCPServer and one green Thread per active
connection, with a bounded admission queue, handler timeouts, and stop/drain.

SPINEL_WORKERS is the total worker budget. For an acceptor on main and two helper
workers, the benchmark sets SPINEL_WORKERS=3 and restricts the process to two CPUs.
No GVL protects application state. Session objects are immutable; database adapters
use a Monitor; connections and buffers are owned by each handler. Native bcrypt
returns through thread-local output; there is no shared request scratch buffer.

HTTP currently closes each response. This is a bounded reference application, not
a claim of feature/performance parity with a general-purpose HTTP server.

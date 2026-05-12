# web/tls.rb — TLS サーバ用ヘルパ (Tier 3 #13)
#
# 注意:
#   - blocking 同期 TLS。fiber + epoll 並行とは統合されていない (sketch)
#   - 実用には SSL_ERROR_WANT_READ/WRITE のハンドリング必要
#   - 本デモでは tls_init のみ呼び出している。tls_accept/recv/send/close は
#     ffi_func 経由で利用可能だが Ruby wrapper は省略 (Spinel 型推論を
#     pin できないため、利用者が直接 H.sp_ssl_* を呼ぶ前提)。
#
# 使い方の sketch:
#   tls_init("/path/to/cert.pem", "/path/to/key.pem")
#   listen_fd = ...                          # 通常通り socket+bind+listen
#   cfd = nb_accept(listen_fd)
#   ssl = H.sp_ssl_accept(cfd)               # handshake (blocking)
#   n = H.sp_ssl_recv_to_buf(ssl, H.req_buf, 4096)
#   H.sp_ssl_send(ssl, "HTTP/1.1 200 OK\r\n\r\nhello")
#   H.sp_ssl_free(ssl)

def tls_init(cert_path, key_path)
  H.sp_ssl_init(cert_path, key_path)
end

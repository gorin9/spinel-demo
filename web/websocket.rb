# web/websocket.rb — WebSocket (RFC 6455) サーバー (Tier 3 #16)
#
# 簡易実装:
#   - text frame のみ
#   - payload 125 byte 以下
#   - 1 fiber = 1 接続 (echo loop は blocking)
#
# 完全実装には extended length、ping/pong、close frame、binary 等が必要。

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# request 全体から Sec-WebSocket-Key の値を抜く
def ws_key(s)
  key_pos = s.index("Sec-WebSocket-Key:")
  return "" if key_pos < 0
  after = s.slice(key_pos + 18, s.length)   # "Sec-WebSocket-Key:" は 18 文字
  # 先頭空白 skip
  start = 0
  while start < after.length && after.slice(start, 1) == " "
    start += 1
  end
  trimmed = after.slice(start, after.length)
  e = trimmed.index("\r")
  return trimmed if e < 0
  trimmed.slice(0, e)
end

# Sec-WebSocket-Accept 計算: base64(SHA1(key + MAGIC))
def ws_accept_value(key)
  H.sp_sha1_b64(key + WS_MAGIC)
end

# handshake response を送信して echo loop に入る
def serve_websocket(cfd, s)
  key = ws_key(s)
  if key == ""
    return false
  end
  accept = ws_accept_value(key)
  resp = "HTTP/1.1 101 Switching Protocols\r\n" \
       + "Upgrade: websocket\r\n" \
       + "Connection: Upgrade\r\n" \
       + "Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
  return false unless nb_send_all(cfd, resp)

  # WS frame パース簡略化のため blocking に戻す。
  # この間、この worker process は ws client 1 つに専有される。
  H.sp_set_blocking(cfd)

  # Echo loop (blocking — 簡易版)
  alive = true
  while alive
    n = H.sp_ws_recv_text(cfd)
    if n < 0
      alive = false
    else
      msg = H.sp_ws_payload_str
      # echo back with prefix
      reply = "echo: " + msg
      if H.sp_ws_send_text(cfd, reply) < 0
        alive = false
      end
    end
  end
  true
end

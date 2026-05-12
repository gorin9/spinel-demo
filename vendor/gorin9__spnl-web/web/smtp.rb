# web/smtp.rb — SMTP クライアント (Tier 3 #19)
#
# プレーン (StartTLS なし) SMTP で送信。
# 依存: H.sp_tcp_connect, H.sp_recv_line, H.sp_line_buf_str, H.sp_send_str, C.close
# 接続は blocking で、handler としては Fiber と非協調 (workr 1 occupied)。

# 1 行レスポンス受信して 3 桁ステータスコード返す。
# 失敗 (EOF / 短すぎ) -1。
def smtp_recv_code(fd)
  n = H.sp_recv_line(fd)
  return -1 if n < 3
  line = H.sp_line_buf_str
  c = line.slice(0, 3)
  c.to_i
end

# 1 行コマンドを送って 3桁レスポンスを受け取って返す。
def smtp_cmd(fd, line)
  H.sp_send_str(fd, line + "\r\n")
  smtp_recv_code(fd)
end

# 送信。成功 true、失敗 false。
# from / to は単一アドレス、body は本文 (CRLF 改行含む RFC 822 メッセージ)
def smtp_send(host, port, from, to, body)
  fd = H.sp_tcp_connect(host, port)
  return false if fd < 0

  ok = true
  ok = false unless smtp_recv_code(fd) == 220
  ok = false unless smtp_cmd(fd, "EHLO spinel.local") == 250 if ok
  ok = false unless smtp_cmd(fd, "MAIL FROM:<" + from + ">") == 250 if ok
  ok = false unless smtp_cmd(fd, "RCPT TO:<" + to + ">") == 250 if ok
  ok = false unless smtp_cmd(fd, "DATA") == 354 if ok
  if ok
    H.sp_send_str(fd, body)
    H.sp_send_str(fd, "\r\n.\r\n")
    ok = false unless smtp_recv_code(fd) == 250
  end
  smtp_cmd(fd, "QUIT") if ok
  C.close(fd)
  ok
end

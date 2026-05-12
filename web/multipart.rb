# web/multipart.rb — multipart/form-data parser (基本) (Tier 2 #9)
#
# 簡易実装の制約:
#   - 1 part のみ抽出 (multi-file unsupported)
#   - body は 1 recv で全部届く前提 (~4KB 以下)
#   - chunked transfer 不対応

# request 全体から Content-Type ヘッダの boundary= 値を抜く
def get_boundary(s)
  ct = s.index("Content-Type:")
  return "" if ct < 0
  rest = s.slice(ct, s.length)
  bp = rest.index("boundary=")
  return "" if bp < 0
  br = rest.slice(bp + 9, rest.length)
  e1 = br.index("\r")
  e2 = br.index("\n")
  e = e1
  e = e2 if e < 0 || (e2 >= 0 && e2 < e)
  return br if e < 0
  br.slice(0, e)
end

# multipart/form-data から最初の part の content だけ抜く。失敗したら "".
def parse_multipart_first(s, boundary)
  body_start = s.index("\r\n\r\n")
  return "" if body_start < 0
  body = s.slice(body_start + 4, s.length)

  delim = "--" + boundary + "\r\n"
  ps = body.index(delim)
  return "" if ps < 0
  after = body.slice(ps + delim.length, body.length)

  hdr_end = after.index("\r\n\r\n")
  return "" if hdr_end < 0
  content_start = hdr_end + 4
  rest = after.slice(content_start, after.length)

  end_delim = "\r\n--" + boundary
  end_pos = rest.index(end_delim)
  return rest if end_pos < 0
  rest.slice(0, end_pos)
end

# web/session.rb — HMAC-SHA256 署名付きセッション (Tier 2 #10)
#
# 依存: H.sp_hmac_sha256_hex, H.sp_consttime_eq
#
# 仕組み: value を HMAC-SHA256 で署名し "value.signature_hex" を cookie に。
# 検証は定数時間比較 (sp_consttime_eq) でタイミング攻撃を防ぐ。

# 本番では env var で外から注入する想定。デモは固定。
SESSION_SECRET = "demo-session-secret-do-not-use-in-prod-32bytes!"

def session_sign(value)
  value + "." + H.sp_hmac_sha256_hex(SESSION_SECRET, value)
end

def session_verify(signed)
  dot = signed.rindex(".")
  return "" if dot < 0
  value = signed.slice(0, dot)
  sig   = signed.slice(dot + 1, signed.length)
  expected = H.sp_hmac_sha256_hex(SESSION_SECRET, value)
  return value if H.sp_consttime_eq(sig, expected) == 1
  ""
end

# リクエスト全体から Cookie の "session=..." 値を抽出 (無ければ "")
def get_session_cookie(s)
  return "" if s.index("Cookie:") < 0
  pos = s.index("session=")
  return "" if pos < 0
  rest = s.slice(pos + 8, s.length)
  e1 = rest.index(";")
  e2 = rest.index("\r")
  e3 = rest.index("\n")
  e = e1
  e = e2 if e < 0 || (e2 >= 0 && e2 < e)
  e = e3 if e < 0 || (e3 >= 0 && e3 < e)
  return rest if e < 0
  rest.slice(0, e)
end

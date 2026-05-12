# web/csrf.rb — CSRF トークン生成・検証 (Tier 3 #15)
#
# 仕組み: UUID v4 をトークンとして使う。サーバが cookie で発行 → クライアントが
# フォーム送信時に body or header にも同じ値を入れる → サーバが consttime 比較。
#
# 依存: H.sp_uuid_v4, H.sp_consttime_eq

# 新しい CSRF トークン (36 char UUID v4)
def csrf_token
  H.sp_uuid_v4
end

# 提出されたトークン vs 期待値の検証 (定数時間比較)
def csrf_valid?(submitted, expected)
  return false if submitted == "" || expected == ""
  H.sp_consttime_eq(submitted, expected) == 1
end

# リクエストから "csrf_token" cookie の値を抽出
def get_csrf_cookie(s)
  return "" if s.index("Cookie:") < 0
  pos = s.index("csrf_token=")
  return "" if pos < 0
  rest = s.slice(pos + 11, s.length)
  e1 = rest.index(";")
  e2 = rest.index("\r")
  e3 = rest.index("\n")
  e = e1
  e = e2 if e < 0 || (e2 >= 0 && e2 < e)
  e = e3 if e < 0 || (e3 >= 0 && e3 < e)
  return rest if e < 0
  rest.slice(0, e)
end

# query string から "token=..." 値を抽出
def get_query_token(path)
  pos = path.index("token=")
  return "" if pos < 0
  rest = path.slice(pos + 6, path.length)
  e = rest.index("&")
  return rest if e < 0
  rest.slice(0, e)
end

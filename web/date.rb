# web/date.rb — pure Spinel 日付フォーマッタ
#
# helper.c の sp_gmtime_str (epoch_secs → "Y M D h m s wday") と
# sp_unix_ms を使って iso8601 / rfc2822 / http-date を Ruby 側で組み立てる。
# format string が言語レベルで見えるのが pure Spinel の旨味。

WDAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
MON_NAMES  = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

def pad2(n)
  n < 10 ? "0" + n.to_s : n.to_s
end

def pad4(n)
  if n < 10
    "000" + n.to_s
  elsif n < 100
    "00" + n.to_s
  elsif n < 1000
    "0" + n.to_s
  else
    n.to_s
  end
end

# 現在 UTC を [year, mon, day, hour, min, sec, wday] (全て int) で返す
def now_parts
  s = H.sp_gmtime_str(H.sp_unix_ms / 1000)
  ps = s.split(" ")
  [ps[0].to_i, ps[1].to_i, ps[2].to_i,
   ps[3].to_i, ps[4].to_i, ps[5].to_i, ps[6].to_i]
end

# RFC 3339 / ISO 8601: "2026-05-10T07:32:41Z"
def iso_now
  p = now_parts
  pad4(p[0]) + "-" + pad2(p[1]) + "-" + pad2(p[2]) + "T" \
    + pad2(p[3]) + ":" + pad2(p[4]) + ":" + pad2(p[5]) + "Z"
end

# RFC 2822: "Sun, 10 May 2026 07:32:41 +0000"
def rfc2822_now
  p = now_parts
  WDAY_NAMES[p[6]] + ", " + pad2(p[2]) + " " + MON_NAMES[p[1] - 1] + " " \
    + pad4(p[0]) + " " + pad2(p[3]) + ":" + pad2(p[4]) + ":" + pad2(p[5]) + " +0000"
end

# RFC 7231 HTTP-date: "Sun, 10 May 2026 07:32:41 GMT"
def http_date_now
  p = now_parts
  WDAY_NAMES[p[6]] + ", " + pad2(p[2]) + " " + MON_NAMES[p[1] - 1] + " " \
    + pad4(p[0]) + " " + pad2(p[3]) + ":" + pad2(p[4]) + ":" + pad2(p[5]) + " GMT"
end

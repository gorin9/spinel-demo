# web/logger.rb — 構造化ロガー (JSON Lines, stderr)
#
# 依存: web/date.rb (iso_now), H.sp_log (stderr 出力)
#
# Spinel の class instance var GC バグを避けるためトップレベル定数 +
# top-level 関数として実装。

LOG_DEBUG = 0
LOG_INFO  = 1
LOG_WARN  = 2
LOG_ERROR = 3
LOG_LEVEL = LOG_INFO   # コンパイル時固定 (Spinel が constant 再代入を許さない)

def log_at(lvl_num, lvl_label, msg)
  return if lvl_num < LOG_LEVEL
  H.sp_log("{\"ts\":\"" + iso_now + "\",\"lvl\":\"" + lvl_label + "\",\"msg\":\"" + msg + "\"}")
end

def log_info(msg); log_at(LOG_INFO, "INFO", msg); end
def log_warn(msg); log_at(LOG_WARN, "WARN", msg); end

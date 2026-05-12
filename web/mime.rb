# web/mime.rb — 拡張子 → Content-Type ルックアップ
#
# Tier 2 #8。Sinatra/Rack の Mime::Types 相当の最小実装。
# 依存: なし (pure Spinel)。

def mime_for(path)
  return "text/html; charset=utf-8"             if path.end_with?(".html")
  return "text/css; charset=utf-8"              if path.end_with?(".css")
  return "application/javascript; charset=utf-8" if path.end_with?(".js")
  return "application/json; charset=utf-8"      if path.end_with?(".json")
  return "image/png"                            if path.end_with?(".png")
  return "image/jpeg"                           if path.end_with?(".jpg")
  return "image/jpeg"                           if path.end_with?(".jpeg")
  return "image/gif"                            if path.end_with?(".gif")
  return "image/svg+xml"                        if path.end_with?(".svg")
  return "image/x-icon"                         if path.end_with?(".ico")
  return "text/plain; charset=utf-8"            if path.end_with?(".txt")
  return "application/pdf"                      if path.end_with?(".pdf")
  return "text/event-stream"                    if path.end_with?(".sse")
  "application/octet-stream"
end

# spinel-demo の Controller + Router 統合実例.
# httpd_async.rb から /site/* のパスを SiteRouter.dispatch に委譲する.
class SiteController
  ROUTES = {
    "/"      => :home,
    "/users" => :users
  }

  def home
    @page_title = "Welcome"
    @message    = "spinel-demo + Controller + Router + ERB が AOT で繋がった瞬間"
    render_home
  end

  def users
    @users      = User.all                  # class method 経由 — Spinel safe
    @page_title = "Users"
    render_users
  end

  # framework helper (生成 dispatcher が呼ぶ)
  def set_chrome(nav, content)
    @active_nav    = nav
    @content       = content
    @site_name     = "spinel-demo"
    @site_tagline  = "Spinel AOT + spnl-erb + spnl-router"
    @year          = "2026"
  end
end

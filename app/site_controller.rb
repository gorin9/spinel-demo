require 'erb'
class SiteController
  ROUTES = {'/' => :home, '/users' => :users}
  def home
    @page_title='Welcome'
    @message='Ruby templates and models, compiled ahead of time.'
    render_home
  end
  def users
    @users=User.all
    @page_title='Users'
    render_users
  end
  def set_chrome(nav,content)
    @active_nav=nav;@content=content;@site_name='spinel-demo';@site_tagline='Thread + socket + generated Ruby';@year=Time.now.year.to_s
  end
end

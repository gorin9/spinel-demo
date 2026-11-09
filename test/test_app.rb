Dir.chdir(File.expand_path('..', __dir__))
require_relative '../app/seed_users'
require_relative '../app'
def assert(x,m);raise m unless x;end
%w[/health /bench /about.html /style.css /app.js /users /uuid /now /site/ /site/users].each do |path|
  req=SpnlUtils::Request.parse("GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n")
  response=Demo.response(req)
  assert(response.status==200,"endpoint #{path}")
end
assert(JSON.parse(Demo.response(SpnlUtils::Request.parse("GET /users HTTP/1.1\r\nHost: x\r\n\r\n")).body).length==2,'users')
puts 'demo endpoint and generated view/model/router integration passed'

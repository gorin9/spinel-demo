require 'erb'
require 'socket'
require 'json'
require 'securerandom'
require 'timeout'
require 'zlib'
require 'spnl_utils'
require 'spnl_web'
require_relative 'app/models/user.generated'
require_relative 'app/site_controller'
require_relative 'views/site/layout.html.generated'
require_relative 'views/site/home.html.generated'
require_relative 'views/site/users.html.generated'
require_relative 'app/site_router.generated'

module Demo
  ROOT = ENV.fetch('SPNL_PUBLIC', 'public')
  BENCH = File.binread(ROOT+'/bench.txt')
  INDEX = File.binread(ROOT+'/index.html')
  ASSETS = {'/index.html'=>INDEX, '/about.html'=>File.binread(ROOT+'/about.html'), '/style.css'=>File.binread(ROOT+'/style.css'), '/app.js'=>File.binread(ROOT+'/app.js')}
  def self.response(request)
    path=request.path
    if path=='/health'
      SpnlUtils::Response.json_body(JSON.generate({'ok'=>true}))
    elsif path=='/bench'
      SpnlUtils::Response.text(BENCH)
    elsif path=='/'
      SpnlUtils::Response.html(INDEX)
    elsif ASSETS.key?(path)
      response=SpnlUtils::Response.text(ASSETS[path]);response.set_ctype(mime_for(path));response
    elsif path=='/users'
      rows=User.all.map { |u| {'id'=>u.id,'name'=>u.name} }
      SpnlUtils::Response.json_body(JSON.generate(rows))
    elsif path=='/uuid'
      SpnlUtils::Response.json_body(JSON.generate({'v4'=>SecureRandom.uuid,'v7'=>SpnlWeb::UUID.v7}))
    elsif path=='/now'
      SpnlUtils::Response.json_body(JSON.generate({'iso'=>iso_now,'http'=>http_date_now}))
    elsif path=='/gz'
      response=SpnlUtils::Response.text(Zlib.gzip(INDEX));response.set_ctype('text/html; charset=utf-8');response.add_header('Content-Encoding','gzip');response
    elsif path=='/bcrypt'
      password=request.query.fetch('p','test123')
      hash=bc_hash(password,10)
      SpnlUtils::Response.json_body(JSON.generate({'hash'=>hash,'self_verify'=>bc_verify(password,hash)}))
    elsif path=='/csrf/verify'
      user=session_verify(request.cookies.fetch('session',''))
      expected=session_verify(request.cookies.fetch('csrf_token',''))
      submitted=request.query.fetch('token','')
      ok=!user.empty? && !submitted.empty? && csrf_valid?(user+':'+submitted,expected)
      SpnlUtils::Response.json_body(JSON.generate({'valid'=>ok}))
    elsif path=='/session'
      value=session_verify(request.cookies.fetch('session',''))
      value=SecureRandom.hex(16) if value.empty?
      response=SpnlUtils::Response.json_body(JSON.generate({'user'=>value}))
      response.set_cookie(SpnlUtils::Cookie.build('session',session_sign(value),'/',3600,true,ENV['SPNL_COOKIE_SECURE']!='0','Strict'))
      response
    elsif path=='/csrf'
      user=session_verify(request.cookies.fetch('session',''))
      user=SecureRandom.hex(16) if user.empty?
      token=csrf_token
      response=SpnlUtils::Response.json_body(JSON.generate({'token'=>token}))
      response.set_cookie(SpnlUtils::Cookie.build('session',session_sign(user),'/',3600,true,ENV['SPNL_COOKIE_SECURE']!='0','Strict'))
      response.set_cookie(SpnlUtils::Cookie.build('csrf_token',SpnlWeb.session.sign(user+':'+token,Time.now.to_i+3600),'/',3600,true,ENV['SPNL_COOKIE_SECURE']!='0','Strict'))
      response
    elsif path=='/upload' && request.method=='POST'
      content_type=request.header('content-type')
      raise ArgumentError,'multipart Content-Type required' if content_type.nil?
      match=content_type.match(/boundary=(?:"([^"]+)"|([^;\s]+))/)
      raise ArgumentError,'boundary required' if match.nil?
      boundary=match[1].nil? ? match[2] : match[1]
      parts=SpnlWeb::Multipart.parse(request.body,boundary)
      SpnlUtils::Response.json_body(JSON.generate({'parts'=>parts.length}))
    elsif path.start_with?('/site/')
      result=SiteRouter.dispatch_result(request.method,path[5,path.length])
      response=SpnlUtils::Response.html(result[1])
      response.set_status(result[0],result[0]==200 ? 'OK' : result[0]==405 ? 'Method Not Allowed' : 'Not Found')
      response.add_header('Allow',result[2]) if result[0]==405
      response
    else
      SpnlUtils::Response.not_found
    end
  end
  def self.handle(client)
    request=SpnlUtils::Request.read(client)
    if request.path=='/ws'
      raise ArgumentError,'invalid upgrade' unless request.method=='GET' && request.header('upgrade').to_s.downcase=='websocket' && request.header('connection').to_s.downcase.split(',').map(&:strip).include?('upgrade') && request.header('sec-websocket-version')=='13'
      key=request.header('sec-websocket-key').to_s
      accept=ws_accept_value(key)
      client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "+accept+"\r\n\r\n")
      ws=SpnlWeb::WebSocket.new(client)
      loop do
        message=ws.read_message
        break if message.nil?
        ws.send_frame(ws.last_opcode,ws.last_opcode==1 ? 'echo: '+message : message)
      end
      return
    elsif request.path=='/events'
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nCache-Control: no-cache\r\n\r\n")
      3.times { |i| client.write("event: tick\ndata: "+i.to_s+"\n\n");sleep 1 }
      return
    end
    if request.method!='GET' && request.method!='HEAD' && request.path!='/upload' && !request.path.start_with?('/site/')
      response=SpnlUtils::Response.text('Method Not Allowed');response.set_status(405,'Method Not Allowed');response.add_header('Allow','GET, HEAD')
    else
      response=response(request)
    end
    client.write(response.to_wire(request.method))
  rescue ArgumentError, EOFError
    client.write(SpnlUtils::Response.bad_request('bad request').to_wire)
  end
  def self.run
    server=SpnlWeb::Server.new(ENV.fetch('HOST','127.0.0.1'),ENV.fetch('PORT','8080').to_i,128)
    trap('TERM') { server.stop }
    trap('INT') { server.stop }
    puts 'listening '+server.port.to_s
    STDOUT.flush
    begin
      server.run { |client| Timeout.timeout(5) { handle(client) } }
    ensure
      server.drain(5.0)
    end
  end
end

# Spinel mini HTTP server (Linux, libc FFI + small C helper)
#
# Build: ./spinel httpd.rb -o httpd
# Run:   ./httpd          # http://0.0.0.0:8080/

module C
  # All in <sys/socket.h> / <netdb.h> — NOT in sp_runtime.h's includes,
  # so we can declare them freely.
  ffi_func :socket,       [:int, :int, :int],          :int
  ffi_func :bind,         [:int, :ptr, :uint32],       :int
  ffi_func :listen,       [:int, :int],                :int
  ffi_func :accept,       [:int, :ptr, :ptr],          :int
  ffi_func :send,         [:int, :str, :size_t, :int], :long

  # close() is in <unistd.h> (pre-included), but our prototype matches
  # `int close(int)` exactly, so no conflict.
  ffi_func :close,        [:int],                      :int

  ffi_func :getaddrinfo,  [:str, :str, :ptr, :ptr],    :int
  ffi_func :freeaddrinfo, [:ptr],                      :void
  ffi_func :gai_strerror, [:int],                      :str
  ffi_func :perror,       [:str],                      :void

  # MSG_NOSIGNAL on Linux — keeps SIGPIPE from killing us when the
  # peer closes early.
  ffi_const :MSG_NOSIGNAL, 16384

  ffi_buffer :ai_out,    8
  ffi_buffer :req_buf,   4096

  # struct addrinfo (Linux/glibc): ai_addrlen@16, ai_addr@24
  ffi_read_u32 :ai_addrlen, 16
  ffi_read_ptr :ai_addr,    24
  ffi_read_ptr :deref_ptr,   0
end

module H
  ffi_lib    "spinelhelper"
  ffi_cflags "-L/opt/spinel-helper"
  ffi_func :sp_recv_str, [:int, :ptr, :size_t], :str
end

PORT = "8080"
ROOT = "."

def parse_path(line)
  i = line.index(" ")
  return "/" if i == nil
  rest = line.slice(i + 1, line.length)
  j = rest.index(" ")
  return rest if j == nil
  rest.slice(0, j)
end

def file_for(path)
  return nil if path.include?("..")
  return ROOT + "/index.html" if path == "/"
  ROOT + path
end

def respond(cfd, status, ctype, body)
  hdr = "HTTP/1.0 " + status + "\r\n" \
      + "Content-Type: " + ctype + "\r\n" \
      + "Content-Length: " + body.bytesize.to_s + "\r\n" \
      + "Connection: close\r\n\r\n"
  C.send(cfd, hdr,  hdr.bytesize, C::MSG_NOSIGNAL)
  C.send(cfd, body, body.bytesize, C::MSG_NOSIGNAL)
end

def serve(cfd)
  s = H.sp_recv_str(cfd, C.req_buf, 4096)
  if s == nil
    C.close(cfd); return
  end
  nl = s.index("\n")
  line = nl == nil ? s : s.slice(0, nl)

  path  = parse_path(line)
  fpath = file_for(path)

  if fpath == nil
    respond(cfd, "400 Bad Request", "text/plain", "bad path\n")
  elsif File.exist?(fpath)
    body = File.read(fpath)
    respond(cfd, "200 OK", "text/html; charset=utf-8", body)
  else
    respond(cfd, "404 Not Found", "text/plain", "not found: " + path + "\n")
  end

  C.close(cfd)
end

rc = C.getaddrinfo("0.0.0.0", PORT, nil, C.ai_out)
if rc != 0
  puts "getaddrinfo: " + C.gai_strerror(rc)
  exit(1)
end
ai      = C.deref_ptr(C.ai_out)
addr    = C.ai_addr(ai)
addrlen = C.ai_addrlen(ai)

fd = C.socket(2, 1, 0)
if fd < 0
  C.perror("socket"); exit(1)
end
if C.bind(fd, addr, addrlen) != 0
  C.perror("bind"); exit(1)
end
if C.listen(fd, 16) != 0
  C.perror("listen"); exit(1)
end
C.freeaddrinfo(ai)

puts "listening on http://0.0.0.0:" + PORT + "/"
loop do
  cfd = C.accept(fd, nil, nil)
  if cfd < 0
    C.perror("accept"); next
  end
  serve(cfd)
end

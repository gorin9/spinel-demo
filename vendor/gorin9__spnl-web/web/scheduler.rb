# web/scheduler.rb — Fiber + epoll scheduler の核 (Spinel 用)
#
# 設計:
#   - 全 FB を append-only な PtrArray (@all) に保持
#   - @ready_idx / @wait_fds / @wait_idx は IntArray (shift/delete_at 可)
#   - 起動可能な fiber は @ready_idx に index で参照
#   - IO 待ちは @wait_fds (fd) と @wait_idx (FB index) の parallel array
#   - epoll_wait → ready 検出 → @ready_idx に戻す
#   - graceful drain: shutdown 後は passive waiter のみで exit
#
# 制約 (Spinel 由来):
#   #5 配列要素型に Fiber 不可 → FB クラスでラップ
#   #6 PtrArray は shift/pop/delete_at 未実装 → int index で参照
#   #10 arr.index(v) は -1 を返す → `wi >= 0` で判定
#   #8 while true は式位置でループしない → forever 変数化

# Fiber wrapper (obj_FB_ptr_array 型に乗せるため)
class FB
  def initialize(f)
    @f = f
  end
  def fiber; @f; end
end

class Scheduler
  def initialize
    # epoll_create1 は fork 後に呼ぶため initialize ではしない
    # (fork 前に作ると親子で同じカーネル epoll を共有してしまう)
    @epfd = -1
    @all = [FB.new(Fiber.new { 0 })]
    @all.clear
    @ready_idx = []
    @wait_fds = []
    @wait_idx = []
    @pending_cfds = []
    @current = -1
    @listen_fd = -1
    @sigfd = -1
    @shutdown = false
    @child_pids = []
  end

  def boot
    @epfd = C.epoll_create1(0)
  end

  def sigfd; @sigfd; end
  def sigfd=(v); @sigfd = v; end
  def shutdown?; @shutdown; end
  def shutdown!; @shutdown = true; end
  def add_child_pid(p); @child_pids.push(p); end

  def shutdown_children
    i = 0
    while i < @child_pids.length
      H.sp_kill(@child_pids[i], 15)   # SIGTERM
      i += 1
    end
  end

  def listen_fd; @listen_fd; end
  def listen_fd=(v); @listen_fd = v; end
  def epfd; @epfd; end

  def add_ready(f)
    idx = @all.length
    @all.push(FB.new(f))
    @ready_idx.push(idx)
  end

  def push_cfd(cfd)
    @pending_cfds.push(cfd)
  end

  def pop_cfd
    @pending_cfds.shift
  end

  def wait_io(fd, events)
    H.sp_epoll_add(@epfd, fd, events)
    @wait_fds.push(fd)
    @wait_idx.push(@current)
    Fiber.yield
  end

  def run
    forever = true
    while forever
      while @ready_idx.length > 0
        idx = @ready_idx.shift
        @current = idx
        fb = @all[idx]
        f = fb.fiber
        f.resume if f.alive?
      end

      if @wait_fds.length == 0
        forever = false
      elsif @shutdown
        # graceful drain: passive waiter のみ残ったら抜ける
        active = 0
        i = 0
        while i < @wait_fds.length
          fd = @wait_fds[i]
          if fd != @listen_fd && fd != @sigfd
            active += 1
          end
          i += 1
        end
        if active == 0
          forever = false
        else
          n = H.sp_epoll_wait_(@epfd, H.events_buf, 64, 100)
          process_events(n)
        end
      else
        n = H.sp_epoll_wait_(@epfd, H.events_buf, 64, -1)
        process_events(n)
      end
    end
  end

  def process_events(n)
    i = 0
    while i < n
      fd = H.sp_event_fd(H.events_buf, i)
      wi = @wait_fds.index(fd)
      if wi >= 0
        fb_idx = @wait_idx[wi]
        @wait_fds.delete_at(wi)
        @wait_idx.delete_at(wi)
        H.sp_epoll_del(@epfd, fd)
        @ready_idx.push(fb_idx)
      end
      i += 1
    end
  end
end

SCHED = Scheduler.new

# ---- non-blocking IO wrappers (auto-yield on EAGAIN) -------------
def nb_accept(fd)
  c = -1
  done = false
  while !done
    c = H.sp_accept_nb(fd)
    if c >= 0
      done = true
    elsif c == -2
      done = true
    else
      SCHED.wait_io(fd, 1)   # EPOLLIN
    end
  end
  c
end

def nb_recv(fd, buf, cap)
  n = -1
  done = false
  while !done
    n = H.sp_recv_nb(fd, buf, cap)
    if n >= 0
      done = true
    elsif n == -2
      n = -1
      done = true
    else
      SCHED.wait_io(fd, 1)
    end
  end
  n
end

def nb_send_all(fd, str)
  remaining = str
  ok = true
  done = false
  while !done
    n = H.sp_send_nb(fd, remaining, remaining.bytesize)
    if n == -2
      H.sp_log("send_all: fatal err fd=" + fd.to_s)
      ok = false
      done = true
    elsif n == -1
      SCHED.wait_io(fd, 4)   # EPOLLOUT
    elsif n == remaining.bytesize
      done = true
    else
      remaining = remaining.slice(n, remaining.bytesize)
    end
  end
  ok
end

# ---- signal watcher fiber: SIGTERM/SIGINT 受信で shutdown フラグ立てる
def run_signal_watch
  H.sp_set_nonblock(SCHED.sigfd)
  forever = true
  while forever
    s = H.sp_signalfd_read(SCHED.sigfd)
    if s > 0
      H.sp_log("worker pid=" + H.sp_getpid.to_s + " got signal " + s.to_s + ", shutting down")
      SCHED.shutdown!
      SCHED.shutdown_children
      C.close(SCHED.listen_fd)
      forever = false
    elsif s == -2
      H.sp_log("signalfd read fatal")
      forever = false
    else
      SCHED.wait_io(SCHED.sigfd, 1)
    end
  end
end

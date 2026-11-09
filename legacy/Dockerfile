# syntax=docker/dockerfile:1.7

FROM ruby:3.3-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 https://github.com/matz/spinel.git
WORKDIR /opt/spinel
RUN make deps && make -j"$(nproc)"

COPY helper.c /opt/spinel-helper/helper.c
RUN cc -O2 -c /opt/spinel-helper/helper.c -o /opt/spinel-helper/helper.o \
 && ar rcs /opt/spinel-helper/libspinelhelper.a /opt/spinel-helper/helper.o

COPY httpd.rb /opt/spinel/httpd.rb
RUN ./spinel httpd.rb -o /opt/httpd

FROM debian:bookworm-slim
COPY --from=builder /opt/httpd /usr/local/bin/httpd
COPY www /srv/www
WORKDIR /srv/www
EXPOSE 8080
CMD ["/usr/local/bin/httpd"]

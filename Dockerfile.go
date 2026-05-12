# syntax=docker/dockerfile:1.7

FROM golang:1.22-bookworm AS builder
WORKDIR /src
COPY httpd.go /src/httpd.go
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /opt/httpd-go /src/httpd.go

FROM debian:bookworm-slim
COPY --from=builder /opt/httpd-go /usr/local/bin/httpd-go
COPY www /srv/www
WORKDIR /srv/www
EXPOSE 8080
CMD ["/usr/local/bin/httpd-go"]

FROM golang:1.27.3-bookworm AS builder
WORKDIR /src
COPY httpd.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /server httpd.go
FROM debian:bookworm-slim
COPY --from=builder /server /usr/local/bin/server
COPY public/bench.txt /srv/public/bench.txt
WORKDIR /srv
ENV HOST=0.0.0.0 PORT=8080
USER 65534:65534
EXPOSE 8080
CMD ["/usr/local/bin/server"]

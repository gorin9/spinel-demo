# Build from the spinel-demo directory. All project and compiler sources are pinned.
FROM ruby:3.3-slim-bookworm AS builder
ARG SPINEL_REF=2814693f6e86b5c0427d9e7a0a7464eba462c64f
ARG SPNL_UTILS_REF=3d9d9577c32285a869c35469604c227c44a477c5
ARG SPNL_WEB_REF=6889a4a76c8af674ecfe22e72fa0630bd33eddf7
ARG SPNL_ERB_REF=af85faf17d022555487b89bf57368714d85d033d
ARG SPNL_ROUTER_REF=b624ae04591c9f5d0a25c84b73b525e6a9e794c2
ARG SPNL_SCHEMA_REF=9952d01256b1b77ffa3a660ff4a0f4d9fa8f5433
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git curl ca-certificates libssl-dev libcrypt-dev libsqlite3-dev pkg-config && rm -rf /var/lib/apt/lists/*
RUN gem install erb -v 2.2.3 --no-document && gem install prism -v 1.9.0 --no-document && gem install sqlite3 -v 1.7.3 --no-document
RUN git init /opt/spinel && git -C /opt/spinel remote add origin https://github.com/matz/spinel.git && git -C /opt/spinel fetch --depth 1 origin "$SPINEL_REF" && git -C /opt/spinel checkout --detach FETCH_HEAD
RUN make -C /opt/spinel deps && make -C /opt/spinel -j2
ENV PATH=/opt/spinel/bin:$PATH
WORKDIR /src
RUN for spec in "spnl-utils:$SPNL_UTILS_REF" "spnl-web:$SPNL_WEB_REF" "spnl-erb:$SPNL_ERB_REF" "spnl-router:$SPNL_ROUTER_REF" "spnl-schema:$SPNL_SCHEMA_REF"; do repo="${spec%%:*}"; ref="${spec#*:}"; git init "$repo" && git -C "$repo" remote add origin "https://github.com/gorin9/$repo.git" && git -C "$repo" fetch --depth 1 origin "$ref" && git -C "$repo" checkout --detach FETCH_HEAD || exit 1; done
COPY . /src/spinel-demo
WORKDIR /src/spinel-demo
RUN ruby scripts/generate.rb && spin build demo
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3 libcrypt1 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/spinel-demo/build/bin/demo /usr/local/bin/demo
COPY --from=builder /src/spinel-demo/public /srv/public
ENV HOST=0.0.0.0 PORT=8080 SPNL_PUBLIC=/srv/public
WORKDIR /srv
USER 65534:65534
EXPOSE 8080
CMD ["/usr/local/bin/demo"]

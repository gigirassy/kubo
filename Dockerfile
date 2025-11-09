# syntax=docker/dockerfile:1

#### Builder: Blop check!
FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.25-alpine AS builder

ARG TARGETOS TARGETARCH
ARG MAKE_TARGET=build
ARG IPFS_PLUGINS

ENV SRC_DIR=/kubo

COPY go.mod go.sum $SRC_DIR/
WORKDIR $SRC_DIR
RUN apk add make bash --no-cache
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . $SRC_DIR

# Attempt static-ish build: CGO disabled, trimmed paths, stripped symbols
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    mkdir -p .git/objects \
    && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
       GOFLAGS='-trimpath' \
       make ${MAKE_TARGET} IPFS_PLUGINS="$IPFS_PLUGINS" LDFLAGS='-s -w'

# Collect runtime artifacts in /out so final stages can COPY from a single place
RUN mkdir -p /out/usr/local/bin \
 && cp -a $SRC_DIR/cmd/ipfs/ipfs /out/usr/local/bin/ipfs 2>/dev/null || true \
 && cp -a $SRC_DIR/bin/container_daemon /out/usr/local/bin/start_ipfs 2>/dev/null || true \
 && cp -a $SRC_DIR/bin/container_init_run /out/usr/local/bin/container_init_run 2>/dev/null || true \
 && chmod 755 /out/usr/local/bin/* || true

#### Final: Alpine runtime (no FUSE)
FROM alpine:latest AS final
ENV IPFS_PATH=/data/ipfs
ENV GOLOG_LOG_LEVEL=""

# Install runtime packages directly in final stage (more robust than copying from utilities)
RUN apk add --no-cache tini su-exec ca-certificates

# Provide a lightweight 'gosu' compatibility symlink if any scripts expect /sbin/gosu
RUN ln -sf /sbin/su-exec /sbin/gosu

# Copy built binaries & scripts from builder
COPY --from=builder /out/usr/local/bin/ipfs /usr/local/bin/ipfs
COPY --from=builder /out/usr/local/bin/start_ipfs /usr/local/bin/start_ipfs
COPY --from=builder /out/usr/local/bin/container_init_run /usr/local/bin/container_init_run

RUN chmod 755 /usr/local/bin/ipfs /usr/local/bin/start_ipfs /usr/local/bin/container_init_run

# user, dirs, permissions
RUN addgroup -g 1000 ipfs \
 && adduser -D -u 1000 -G ipfs ipfs \
 && mkdir -p $IPFS_PATH /ipfs /ipns /mfs /container-init.d \
 && chown ipfs:ipfs $IPFS_PATH /ipfs /ipns /mfs /container-init.d

VOLUME $IPFS_PATH
EXPOSE 4001 4001/udp 5001 8080 8081

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/start_ipfs"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ipfs --api=/ip4/127.0.0.1/tcp/5001 dag stat /ipfs/QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn || exit 1

CMD ["daemon", "--migrate=true", "--agent-version-suffix=docker"]

#### Final with FUSE: installs fuse and sets SUID on fusermount if present
FROM alpine:latest AS final-fuse
ENV IPFS_PATH=/data/ipfs
ENV GOLOG_LOG_LEVEL=""

RUN apk add --no-cache tini su-exec ca-certificates fuse

RUN ln -sf /sbin/su-exec /sbin/gosu

COPY --from=builder /out/usr/local/bin/ipfs /usr/local/bin/ipfs
COPY --from=builder /out/usr/local/bin/start_ipfs /usr/local/bin/start_ipfs
COPY --from=builder /out/usr/local/bin/container_init_run /usr/local/bin/container_init_run

RUN chmod 755 /usr/local/bin/ipfs /usr/local/bin/start_ipfs /usr/local/bin/container_init_run || true

# set SUID for fusermount if it's installed in common locations
RUN if [ -e /usr/bin/fusermount ]; then chmod 4755 /usr/bin/fusermount; \
    elif [ -e /bin/fusermount ]; then chmod 4755 /bin/fusermount; fi || true

RUN addgroup -g 1000 ipfs \
 && adduser -D -u 1000 -G ipfs ipfs \
 && mkdir -p $IPFS_PATH /ipfs /ipns /mfs /container-init.d \
 && chown ipfs:ipfs $IPFS_PATH /ipfs /ipns /mfs /container-init.d

VOLUME $IPFS_PATH
EXPOSE 4001 4001/udp 5001 8080 8081

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/start_ipfs"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ipfs --api=/ip4/127.0.0.1/tcp/5001 dag stat /ipfs/QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn || exit 1

CMD ["daemon", "--migrate=true", "--agent-version-suffix=docker"]

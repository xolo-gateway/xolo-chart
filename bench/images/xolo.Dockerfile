# Development image of Xolo, built from a working copy so the chart can be
# tested against unreleased changes. The build context is the Xolo checkout:
#
#   docker build -f bench/images/xolo.Dockerfile -t xolo-server:dev ../xolo
#
# Released deployments use ghcr.io/xolo-gateway/xolo-server instead.
FROM golang:1.27-alpine AS build
RUN apk add --no-cache git
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o /out/xolo-server ./cmd/server && \
    for p in $(ls plugins | grep -v internal); do \
      CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o /out/plugins/$p ./plugins/$p || exit 1; \
    done

FROM alpine:3.23
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/xolo-server /usr/local/bin/xolo-server
COPY --from=build /out/plugins /plugins
ENV XOLO_PLUGINS_DIR=/plugins
EXPOSE 3002
CMD ["/usr/local/bin/xolo-server"]

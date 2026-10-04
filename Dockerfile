# syntax=docker/dockerfile:1

FROM node:26-alpine AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY web/ ./
RUN npm run build

FROM golang:1.27-alpine AS go
ENV CGO_ENABLED=0
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download

FROM go AS deps
COPY server/ ./
RUN go list -deps -tags dev -f '{{with .Module}}{{if not .Main}}{{$.ImportPath}}{{end}}{{end}}' ./... > /deps

# The Go build cache lives in layers, not a cache mount, so it carries over
# wherever layers are cached: third-party packages only recompile when the
# imports change, and a frontend-only change only recompiles package main.
FROM go AS build
COPY --from=deps /deps /deps
RUN go build -trimpath $(cat /deps)
COPY server/ ./
# -tags dev leaves out the embed, which needs the frontend.
RUN go build -trimpath -tags dev ./...
COPY --from=web /src/server/webui ./webui
RUN go build -trimpath -ldflags="-s -w" -o /out/checkcheck .
# Copied as rootfs/ so --chown also reaches the data directory itself, which a
# new named volume inherits.
RUN mkdir -p /out/rootfs/data

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build --chown=65532:65532 /out/rootfs/ /
COPY --from=build /out/checkcheck /checkcheck
ENV CHECKCHECK_DATA_DIR=/data CHECKCHECK_ADDR=:8080
EXPOSE 8080
VOLUME /data
ENTRYPOINT ["/checkcheck"]

# syntax=docker/dockerfile:1

FROM node:26-alpine AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY web/ ./
RUN npm run build

FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=web /src/web/dist ./web/dist
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/checkcheck .
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

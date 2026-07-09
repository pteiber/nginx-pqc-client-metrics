# Run the build stage on the host's native platform to avoid QEMU emulation.
# Go cross-compiles via GOOS/GOARCH; no emulation needed.
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS=linux
ARG TARGETARCH=amd64
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /go-dual-share .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=build /go-dual-share /usr/local/bin/go-dual-share
ENTRYPOINT ["/usr/local/bin/go-dual-share"]

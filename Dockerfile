#
# Copyright 2026 The Sigstore Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Debian 13 (Trixie) image to build binary for distroless/static-debian13
FROM --platform=$BUILDPLATFORM golang:1.27.3-trixie@sha256:af1bfc2614ebb1dbd31af514b78740fd678850e76498762b425ecee4c5c6ea80 AS builder
ARG TARGETOS
ARG TARGETARCH
ENV APP_ROOT=/opt/app-root
ENV GOPATH=$APP_ROOT

WORKDIR $APP_ROOT/src/
ADD go.mod go.sum* tools.go $APP_ROOT/src/
RUN go mod download

ARG SERVER_LDFLAGS
# Build vindexd server for deployment from pinned upstream module
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 go build -trimpath -ldflags "${SERVER_LDFLAGS}" -o vindexd github.com/transparency-dev/incubator/vindex/cmd/vindexd

# Pre-create persistent disk and WASM mount points so Docker named volumes inherit nonroot (65532:65532) ownership
RUN mkdir -p /mnt/disks/data /mnt/disks/mpt /etc/vindex

# Production deployment build
FROM gcr.io/distroless/static-debian13:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5 AS deploy
# Retrieve the binary and mount directories from the builder stage
COPY --from=builder /opt/app-root/src/vindexd /usr/local/bin/vindexd
COPY --from=builder --chown=65532:65532 /mnt/disks /mnt/disks
COPY --from=builder --chown=65532:65532 /etc/vindex /etc/vindex
EXPOSE 8080 9090
ENTRYPOINT ["/usr/local/bin/vindexd"]

# Local deployment build (includes a shell and curl)
FROM golang:1.27.3-trixie@sha256:af1bfc2614ebb1dbd31af514b78740fd678850e76498762b425ecee4c5c6ea80 AS local-deploy
COPY --from=builder /opt/app-root/src/vindexd /usr/local/bin/vindexd
COPY --from=builder --chown=65532:65532 /mnt/disks /mnt/disks
COPY --from=builder --chown=65532:65532 /etc/vindex /etc/vindex
USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["/usr/local/bin/vindexd"]

# Cross-compile dlv for the debug stage
FROM builder AS dlvbuilder
ARG TARGETOS
ARG TARGETARCH
ENV APP_ROOT=/opt/app-root
ENV GOPATH=$APP_ROOT
RUN mkdir -p /opt/app-root/bin/${TARGETOS}_${TARGETARCH}
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go install github.com/go-delve/delve/cmd/dlv@latest

# Build debug binary
FROM builder AS debug-builder
ARG TARGETOS
ARG TARGETARCH
ARG SERVER_LDFLAGS
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} CGO_ENABLED=0 go build -gcflags "all=-N -l" -ldflags "${SERVER_LDFLAGS}" -o vindexd_debug github.com/transparency-dev/incubator/vindex/cmd/vindexd

# Multi-stage debugger build
FROM golang:1.27.3-trixie@sha256:af1bfc2614ebb1dbd31af514b78740fd678850e76498762b425ecee4c5c6ea80 AS debug
ARG TARGETOS
ARG TARGETARCH
COPY --from=dlvbuilder /opt/app-root/bin/dlv* /opt/app-root/bin/${TARGETOS}_${TARGETARCH}/dlv* /usr/local/bin/
COPY --from=debug-builder /opt/app-root/src/vindexd_debug /usr/local/bin/vindexd
COPY --from=builder --chown=65532:65532 /mnt/disks /mnt/disks
COPY --from=builder --chown=65532:65532 /etc/vindex /etc/vindex
EXPOSE 8080 9090 2345
ENTRYPOINT ["/usr/local/bin/vindexd"]

# Go builder

ARG REGISTRY=
ARG GO_VERSION=1.27
FROM ${REGISTRY}golang:${GO_VERSION} AS builder

# certspotter's own go.mod pins vulnerable golang.org/x/* transitives, and
# `go install @latest` cannot inject a bump (MVS uses the module's own pins).
# Build from a scratch module instead and raise the x/* versions explicitly.
# Re-pin on the next "con correzione" alert: bump CERTSPOTTER_VERSION together
# with the three X*_VERSION args (targets = grype's `fixedIn`).
# CERTSPOTTER_VERSION is the bare release (no leading "v"); the `@v` prefix below
# is added in go get, and main.Version is set to the same bare value via -ldflags
# so `certspotter --version` reports it unchanged (the go.mod pins would otherwise
# make the buildinfo fallback print "unknown").
#
# The three X*_VERSION args are the golang.org/x/* releases fixed for the CVEs;
# they form a synchronized train (x/crypto v0.57.0 <-> x/net v0.59.0 <-> x/text
# v0.42.0), so bump them as a set, not one at a time.
ARG CERTSPOTTER_VERSION=0.25.0
ARG XCRYPTO_VERSION=v0.57.0
ARG XNET_VERSION=v0.59.0
ARG XTEXT_VERSION=v0.42.0

WORKDIR /src
RUN go mod init builder && \
    go get software.sslmate.com/src/certspotter/cmd/certspotter@v${CERTSPOTTER_VERSION} && \
    go get golang.org/x/crypto@${XCRYPTO_VERSION} golang.org/x/net@${XNET_VERSION} golang.org/x/text@${XTEXT_VERSION} && \
    mkdir -p /go/bin && \
    CGO_ENABLED=0 go build \
        -ldflags "-X main.Version=${CERTSPOTTER_VERSION} -X main.Source=software.sslmate.com/src/certspotter" \
        -o /go/bin/certspotter \
        software.sslmate.com/src/certspotter/cmd/certspotter && \
    /go/bin/certspotter --version

# Final image

FROM ${REGISTRY}debian:latest

#ENV TINI_VERSION v0.18.0

# ARG changes daily (passed from CI as $(date +%Y%m%d)) so this RUN's
# cache key invalidates once per day, picking up newly-published security
# patches via `apt upgrade` against current debian repos.
ARG CACHEBUST_DAY=unset
RUN echo "cache day: ${CACHEBUST_DAY}" && \
  apt-get update && apt-get -y upgrade && \
  apt-get install -y curl && \
  rm -rf /var/lib/apt/lists/*

ADD https://github.com/krallin/tini/releases/latest/download/tini /tini

RUN mkdir /certspotter/ && \
  cd /certspotter && \
  mkdir .certspotter bin base-hooks.d && \
  chown -R 65534:65534 /certspotter && \
  usermod --home /certspotter nobody

COPY --from=builder /go/bin/certspotter /certspotter/bin/certspotter

ADD docker-entrypoint.sh /certspotter/bin/docker-entrypoint.sh
ADD base-hooks.d/* /certspotter/base-hooks.d/
ADD utils.bash /certspotter/
ADD notify.sh /certspotter/bin/notify.sh
RUN chmod +x /tini /certspotter/bin/docker-entrypoint.sh /certspotter/bin/notify.sh /certspotter/bin/certspotter /certspotter/base-hooks.d/*
RUN ln -sf /certspotter/base-hooks.d /certspotter/.certspotter/hooks.d

USER nobody:nogroup

ENTRYPOINT ["/tini", "--", "/certspotter/bin/docker-entrypoint.sh"]


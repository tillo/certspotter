# Go builder

ARG REGISTRY=
ARG GO_VERSION=1.27
FROM ${REGISTRY}golang:${GO_VERSION} AS builder

# certspotter's own go.mod pins vulnerable golang.org/x/* transitives, and
# `go install @latest` cannot inject a bump (MVS uses the module's own pins).
# Build from a scratch module instead and raise the x/* versions explicitly.
# Renovate moves every pin below: the `# renovate:` line directly above each ARG is
# read by customManagers:dockerfileVersions (from local>mdapi/renovate-config:image-repo),
# so its fields must stay in Renovate's order and the line must stay adjacent.
# CERTSPOTTER_VERSION is the bare release (no leading "v"); the `@v` prefix below
# is added in go get, and main.Version is set to the same bare value via -ldflags
# so `certspotter --version` reports it unchanged (the go.mod pins would otherwise
# make the buildinfo fallback print "unknown").
#
# The three X*_VERSION args are floors raised over certspotter's own go.mod pins;
# they form a synchronized train (x/crypto <-> x/net <-> x/text), which renovate.json
# groups into one MR so one build proves the set.
# renovate: datasource=go depName=software.sslmate.com/src/certspotter extractVersion=^v(?<version>.+)$
ARG CERTSPOTTER_VERSION=0.26.2
# renovate: datasource=go depName=golang.org/x/crypto
ARG XCRYPTO_VERSION=v0.57.0
# renovate: datasource=go depName=golang.org/x/net
ARG XNET_VERSION=v0.59.0
# renovate: datasource=go depName=golang.org/x/text
ARG XTEXT_VERSION=v0.43.0

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

# A major tag, not `latest`: the daily CACHEBUST rebuild still takes every 13.x point
# release and security fix, and Renovate's dockerfile manager proposes debian 14 as a
# reviewed MR instead of the rebuild switching release underneath the image.
FROM ${REGISTRY}debian:13

# The tini SHA256 is re-pinned by mdapi/fleet's tools/repin_sha256.py whenever Renovate
# moves TINI_VERSION: it hashes the one URL below that expands ${TINI_VERSION}.
# renovate: datasource=github-releases depName=krallin/tini
ARG TINI_VERSION=v0.19.0
ARG TINI_SHA256=93dcc18adc78c65a028a84799ecf8ad40c936fdfc5f2a57b1acda5a8117fa82c

# ARG changes daily (passed from CI as $(date +%Y%m%d)) so this RUN's
# cache key invalidates once per day, picking up newly-published security
# patches via `apt upgrade` against current debian repos.
ARG CACHEBUST_DAY=unset
RUN echo "cache day: ${CACHEBUST_DAY}" && \
  apt-get update && apt-get -y upgrade && \
  apt-get install -y curl && \
  rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tini "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini" && \
  echo "${TINI_SHA256}  /tini" | sha256sum -c -

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


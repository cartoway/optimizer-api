# syntax=docker/dockerfile:1.4
# Rosomaxa: ROSOMAXA_SOURCE=release → GHCR tag; ROSOMAXA_SOURCE=git → build from git ref/SHA.
ARG ROSOMAXA_SOURCE=release
ARG ROSOMAXA_VERSION=1.25.0
ARG ROSOMAXA_GIT_URL=https://github.com/reinterpretcat/vrp.git
# Pin: reinterpretcat/vrp master @ 2026-09-21 (Fix clippy warnings)
ARG ROSOMAXA_GIT_REF=e49bee0eccb9d732d0e020d7f9bbbb378e2de2bc

FROM ghcr.io/reinterpretcat/vrp/vrp-cli:${ROSOMAXA_VERSION} AS rosomaxa-release

FROM rust:1.95-alpine AS rosomaxa-git
RUN apk add --no-cache musl-dev git
ARG ROSOMAXA_GIT_URL
ARG ROSOMAXA_GIT_REF
WORKDIR /src
# Works for branch names and full commit SHAs.
RUN git init \
    && git remote add origin "${ROSOMAXA_GIT_URL}" \
    && git fetch --depth 1 origin "${ROSOMAXA_GIT_REF}" \
    && git checkout FETCH_HEAD
RUN cargo build --locked --release -p vrp-cli \
    && mkdir -p /solver \
    && cp target/release/vrp-cli /solver/vrp-cli

FROM rosomaxa-${ROSOMAXA_SOURCE} AS rosomaxa-cli

FROM ghcr.io/cartoway/optimizer-ortools:master

COPY --from=rosomaxa-cli /solver/vrp-cli /usr/local/bin/vrp-cli

ARG BUNDLE_WITHOUT="test development rubocop"
# Install Vroom (build deps purged in the same layer)
ARG VROOM_RELEASE=v1.14.0
ARG VROOM_GIT_URL=https://github.com/braktar/vroom.git
ARG VROOM_BRANCH=waiting-time
RUN apt update -y && \
    echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list.d/trixie.list && \
    apt update -y && \
    apt install -y --no-install-recommends \
        git-core \
        build-essential \
        g++ \
        gcc-13 \
        g++-13 \
        netcat-traditional && \
    git clone "$VROOM_GIT_URL" vroom && \
    cd vroom && \
    if [ -n "$VROOM_BRANCH" ]; then \
      git fetch origin "$VROOM_BRANCH" && \
      git checkout -q "$VROOM_BRANCH"; \
    else \
      git fetch --tags && \
      git checkout -q "$VROOM_RELEASE"; \
    fi && \
    git submodule sync --recursive && \
    git submodule update --init --recursive && \
    cd src && \
    CC=gcc-13 CXX=g++-13 \
    make -j"$(nproc)" USE_ROUTING=false \
      CXXFLAGS='-MMD -MP -I. -std=c++20 -Wextra -Wpedantic -Wall -O3 -DNDEBUG -DUSE_ROUTING=false' && \
    cp ../bin/vroom /usr/local/bin/vroom && \
    strip /usr/local/bin/vroom && \
    cd / && \
    rm -rf /vroom && \
    apt-get purge -y --auto-remove \
        git-core build-essential g++ gcc-13 g++-13 && \
    rm -rf /var/lib/apt/lists/*

RUN apt update -y && apt install -y --no-install-recommends \
        python3 \
        python-is-python3 \
        python3-pip \
        python3-venv && \
    rm -rf /var/lib/apt/lists/*

ARG PYVRP_VERSION=0.14.0
# PYVRP_BRANCH can be: a branch name (e.g. "main"), a tag (e.g. "v0.12.1"), or a commit SHA
# ARG PYVRP_BRANCH=
ARG PYVRP_GIT_URL=https://github.com/PyVRP/PyVRP.git

# matplotlib is a declared pyvrp dep (plot helpers only); solver imports work without it.
RUN python -m venv /opt/pyenv && \
    /opt/pyenv/bin/pip install --upgrade pip && \
    /opt/pyenv/bin/pip install numpy && \
    if [ -z "$PYVRP_BRANCH" ]; then \
        /opt/pyenv/bin/pip install pyvrp=="$PYVRP_VERSION"; \
    else \
        /opt/pyenv/bin/pip install git+$PYVRP_GIT_URL@$PYVRP_BRANCH; \
    fi && \
    /opt/pyenv/bin/pip uninstall -y matplotlib pillow fonttools contourpy cycler kiwisolver pyparsing python-dateutil || true && \
    /opt/pyenv/bin/pip cache purge && \
    rm -rf /root/.cache/pip
ENV PATH="/opt/pyenv/bin:$PATH"

ENV LANG C.UTF-8

WORKDIR /srv/app

# balanced_vrp_clustering (bump): Rust native ext via rb_sys — https://github.com/cartoway/balanced_vrp_clustering/tree/bump
# SOURCE_DATE_EPOCH: RubyGems sets it during native compile; helps rb_sys/cargo detection during bundle install.
ENV SOURCE_DATE_EPOCH=1

ADD ./Gemfile /srv/app/
ADD ./Gemfile.lock /srv/app/
# Install native build deps, bundle, then drop compilers/headers (keep runtime libs).
RUN apt update && \
    libgeos=$(apt-cache search 'libgeos-' | grep -P 'libgeos-\d.*' | awk '{print $1}') && \
    libicu=$(apt-cache search '^libicu[0-9]' | awk '{print $1}' | head -1) && \
    apt install -y --no-install-recommends \
        git \
        libgeos-dev \
        ${libgeos} \
        libicu-dev \
        ${libicu} \
        rustc \
        cargo \
        pkg-config \
        libssl-dev \
        libclang-dev \
        clang && \
    apt-mark manual ${libgeos} ${libicu} && \
    bundle config set --local without "${BUNDLE_WITHOUT}" && \
    bundle install --full-index && \
    apt-get purge -y --auto-remove \
        git rustc cargo clang libclang-dev \
        libgeos-dev libicu-dev libssl-dev pkg-config \
        python3-pip && \
    rm -rf /var/lib/apt/lists/* /root/.cargo /tmp/*

ADD . /srv/app

EXPOSE 80

HEALTHCHECK \
    --start-period=30s \
    --interval=30s \
    --timeout=20s \
    --retries=5 \
    CMD wget --no-verbose --tries=1 -O /dev/null http://127.0.0.1:80/ping || exit 1

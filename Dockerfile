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
# Install Vroom
ARG VROOM_RELEASE=v1.14.0
ARG VROOM_GIT_URL=https://github.com/braktar/vroom.git
ARG VROOM_BRANCH=waiting-time
RUN apt update -y && \
    echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list.d/trixie.list && \
    apt update -y && \
    apt install -y \
        git-core \
        build-essential \
        g++ \
        gcc-13 \
        g++-13 \
        libssl-dev \
        libasio-dev \
        libglpk-dev \
        pkg-config \
        netcat-traditional
RUN git clone "$VROOM_GIT_URL" vroom && \
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
    make -j"$(nproc)" \
      CXXFLAGS='-MMD -MP -I. -std=c++20 -Wextra -Wpedantic -Wall -O3 -DNDEBUG -DASIO_STANDALONE -DUSE_ROUTING=true' && \
    cp ../bin/vroom /usr/local/bin/vroom && \
    strip /usr/local/bin/vroom && \
    cd /

RUN apt update -y && apt install -y \
        python3 \
        python-is-python3 \
        python3-pip \
        python3-venv

ARG PYVRP_VERSION=0.14.0
# PYVRP_BRANCH can be: a branch name (e.g. "main"), a tag (e.g. "v0.12.1"), or a commit SHA
# ARG PYVRP_BRANCH=
ARG PYVRP_GIT_URL=https://github.com/PyVRP/PyVRP.git

RUN python -m venv /opt/pyenv && \
    /opt/pyenv/bin/pip install --upgrade pip && \
    /opt/pyenv/bin/pip install numpy && \
    if [ -z "$PYVRP_BRANCH" ]; then \
        /opt/pyenv/bin/pip install pyvrp=="$PYVRP_VERSION"; \
    else \
        /opt/pyenv/bin/pip install git+$PYVRP_GIT_URL@$PYVRP_BRANCH; \
    fi
ENV PATH="/opt/pyenv/bin:$PATH"

ENV LANG C.UTF-8

WORKDIR /srv/app

RUN apt update && \
    libgeos=$(apt-cache search 'libgeos-' | grep -P 'libgeos-\d.*' | awk '{print $1}') && \
    apt install -y --no-install-recommends \
        git \
        libgeos-dev \
        ${libgeos} \
        libicu-dev \
        libglpk-dev \
        nano \
        rustc \
        cargo \
        pkg-config \
        libssl-dev \
        libclang-dev \
        clang \
    && rm -rf /var/lib/apt/lists/*

# balanced_vrp_clustering (bump): Rust native ext via rb_sys — https://github.com/cartoway/balanced_vrp_clustering/tree/bump
# SOURCE_DATE_EPOCH: RubyGems sets it during native compile; helps rb_sys/cargo detection during bundle install.
ENV SOURCE_DATE_EPOCH=1

ADD ./Gemfile /srv/app/
ADD ./Gemfile.lock /srv/app/
RUN bundle config set --local without "${BUNDLE_WITHOUT}" && \
    bundle install --full-index

ADD . /srv/app

EXPOSE 80

HEALTHCHECK \
    --start-period=30s \
    --interval=30s \
    --timeout=20s \
    --retries=5 \
    CMD wget --no-verbose --tries=1 -O /dev/null http://127.0.0.1:80/ping || exit 1

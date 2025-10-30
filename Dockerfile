FROM ghcr.io/cartoway/optimizer-ortools:master

ARG BUNDLE_WITHOUT="test development"
# Install Vroom
ARG VROOM_RELEASE=v1.14.0
RUN apt update -y && \
    apt install -y \
        git-core \
        build-essential \
        g++ \
        libssl-dev \
        libasio-dev \
        libglpk-dev \
        pkg-config \
        netcat-traditional
RUN git clone --recurse-submodules https://github.com/VROOM-Project/vroom.git && \
    cd vroom/src && \
    git fetch --tags && \
    git checkout -q $VROOM_RELEASE && \
    make -j$(nproc) && \
    cp ../bin/vroom /usr/local/bin && \
    cd /

RUN apt update -y && apt install -y \
        python3 \
        python-is-python3 \
        python3-pip \
        python3-venv

ARG PYVRP_VERSION=0.12.1
ARG PYVRP_GIT_URL=https://github.com/PyVRP/PyVRP.git

RUN python -m venv /opt/pyenv && \
    /opt/pyenv/bin/pip install --upgrade pip && \
    /opt/pyenv/bin/pip install numpy && \
    # /opt/pyenv/bin/pip install pyvrp=="$PYVRP_VERSION"
    /opt/pyenv/bin/pip install git+$PYVRP_GIT_URL
ENV PATH="/opt/pyenv/bin:$PATH"

ENV LANG C.UTF-8

WORKDIR /srv/app

RUN apt update && \
    libgeos=$(apt-cache search 'libgeos-' | grep -P 'libgeos-\d.*' | awk '{print $1}') && \
    apt install -y git libgeos-dev ${libgeos} libicu-dev libglpk-dev nano

ADD ./Gemfile /srv/app/
ADD ./Gemfile.lock /srv/app/
RUN bundle install --full-index --without ${BUNDLE_WITHOUT}

ADD . /srv/app

EXPOSE 80

HEALTHCHECK \
    --start-interval=1s \
    --start-period=30s \
    --interval=30s \
    --timeout=20s \
    --retries=5 \
    CMD wget --no-verbose --tries=1 -O /dev/null http://127.0.0.1:80/ping || exit 1

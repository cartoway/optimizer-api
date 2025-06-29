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

ENV LANG C.UTF-8

WORKDIR /srv/app

RUN apt update && \
    libgeos=$(apt-cache search 'libgeos-' | grep -P 'libgeos-\d.*' | awk '{print $1}') && \
    apt install -y git libgeos-dev ${libgeos} libicu-dev libglpk-dev nano

ADD ./Gemfile /srv/app/
ADD ./Gemfile.lock /srv/app/
RUN bundle install --full-index --without ${BUNDLE_WITHOUT}

ADD . /srv/app

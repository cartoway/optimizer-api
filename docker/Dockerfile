ARG VROOM_VERSION

# Install Vroom
FROM vroomvrp/vroom-docker:${VROOM_VERSION:-v1.12.0} as vroom

FROM optimizer-ortools:w1.10.0

COPY --from=vroom /usr/local/bin /srv/vroom/bin

ENV LANG C.UTF-8

WORKDIR /srv/app

# # Set correct environment variables.
# RUN apt update && apt install -y \
#       python3.8 python3-pip && \
# 	  pip3 install protobuf==3.20.* && \
#     pip3 install schema && \
#     pip3 install scikit-learn
# RUN pip3 install unconstrained-initialization/dependencies/fastvrpy-0.5.2.tar.gz --user

RUN apt update && \
    libgeos=$(apt-cache search 'libgeos-' | grep -P 'libgeos-\d.*' | awk '{print $1}') && \
    apt install -y git libgeos-dev ${libgeos} libicu-dev libglpk-dev nano

ADD ./Gemfile /srv/app/
ADD ./Gemfile.lock /srv/app/
RUN bundle install --full-index --without test development

ADD . /srv/app

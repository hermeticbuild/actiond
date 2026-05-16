FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bc \
        bison \
        ca-certificates \
        flex \
        gcc \
        git \
        libc6-dev \
        libelf-dev \
        libssl-dev \
        make \
        perl \
        rsync \
        xz-utils \
    && if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
        apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu; \
    fi \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT []
CMD ["/bin/bash"]

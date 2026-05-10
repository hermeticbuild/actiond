FROM gcr.io/bazel-public/bazel:9.1.0

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bc \
        bison \
        ca-certificates \
        flex \
        gcc \
        gcc-aarch64-linux-gnu \
        git \
        libc6-dev \
        libelf-dev \
        libssl-dev \
        make \
        perl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

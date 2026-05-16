FROM ubuntu:24.04

ARG BAZELISK_VERSION=v1.29.0
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bc \
        bison \
        ca-certificates \
        curl \
        flex \
        gcc \
        gcc-aarch64-linux-gnu \
        g++ \
        git \
        libc6-dev \
        libelf-dev \
        libssl-dev \
        make \
        perl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) bazelisk_arch=amd64 ;; \
        arm64) bazelisk_arch=arm64 ;; \
        *) echo "unsupported Bazelisk architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fL "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${bazelisk_arch}" -o /usr/local/bin/bazel; \
    chmod +x /usr/local/bin/bazel; \
    bazel --version

WORKDIR /work
ENTRYPOINT []
CMD ["/bin/bash"]

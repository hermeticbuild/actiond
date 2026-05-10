FROM gcr.io/bazel-public/bazel:9.1.0

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates bash git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

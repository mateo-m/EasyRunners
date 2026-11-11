# syntax=docker/dockerfile:1.7
# The runner image of the voir and empo-app CI. Build it on top of the runner
# target of runner/Dockerfile, with that image as the `base` build context.
FROM node:22-bookworm-slim AS node
FROM oven/bun:1.4.0 AS bun
FROM base
ARG TARGETARCH
USER root
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# PostgreSQL 18 comes from the PGDG repository: Ubuntu 24.04 ships 16.
# The voir CI starts its own server with initdb, thus the package must
# not make a cluster.
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && apt-get update \
    && npx -y playwright@1.62.1 install-deps chromium firefox webkit \
    && apt-get install -y --no-install-recommends ffmpeg pulseaudio postgresql-common \
    && echo "create_main_cluster = false" >> /etc/postgresql-common/createcluster.conf \
    && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
    && apt-get install -y --no-install-recommends postgresql-18 \
    && rm -rf /var/lib/apt/lists/* /root/.npm
# Ubuntu 24.04 ships no Valkey 9, thus the image takes the build of
# valkey.io. The voir CI starts its own server.
RUN case "$TARGETARCH" in \
      amd64) arch=x86_64 sha=26416df8a5b075ffb7d549e9a6445db9ec16e36d2259d8ea6e010dca35d53a54 ;; \
      arm64) arch=arm64 sha=bf77cf1adf9dc2b1e1f42a01b611b5b8d00c5c158a200ab9ad1f8837d84d59da ;; \
      *) echo "no Valkey build for $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && asset="valkey-9.1.3-noble-$arch" \
    && curl -fsSL -o /tmp/valkey.tar.gz "https://download.valkey.io/releases/$asset.tar.gz" \
    && echo "$sha  /tmp/valkey.tar.gz" | sha256sum --check --strict \
    && mkdir /opt/valkey \
    && tar -xzf /tmp/valkey.tar.gz -C /opt/valkey --strip-components 1 \
    && rm /tmp/valkey.tar.gz \
    && ln -s /opt/valkey/bin/valkey-server /opt/valkey/bin/valkey-cli /usr/local/bin/ \
    && valkey-server --version
# The jobs cannot use sudo, so the tools that empo-app CI installs with
# apt or swiftly ship here.
RUN case "$TARGETARCH" in \
      amd64) arch=amd64 swift_os=ubuntu2404 swift_suffix= \
        shfmt_sha=fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1 \
        swift_sha=69f7b2b4dbce6090b6c92194b71149a057e16269093b5a9dded38afc4a05094e \
        swiftlint_sha=dd1017cfd20a1457f264590bcb5875a6ee06cd75b9a9d4f77cd43a552499143b ;; \
      arm64) arch=arm64 swift_os=ubuntu2404-aarch64 swift_suffix=-aarch64 \
        shfmt_sha=32d92acaa5cd8abb29fc49dac123dc412442d5713967819d8af2c29f1b3857c7 \
        swift_sha=21eacfe571194717d269cc1e0030533bbee6131dfde82cd4f9cfbc2512e354a9 \
        swiftlint_sha=104dedff762157f5cff7752f1cc2a289b60f3ea677e72d651c6f3a3287fdd948 ;; \
      *) echo "no tools for $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      gh shellcheck yamllint clang-format-18 \
      binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
      libncurses-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev libxml2-dev \
      libz3-dev tzdata zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /usr/local/bin/shfmt \
      "https://github.com/mvdan/sh/releases/download/v3.13.1/shfmt_v3.13.1_linux_${arch}" \
    && echo "${shfmt_sha}  /usr/local/bin/shfmt" | sha256sum --check --strict \
    && chmod 0755 /usr/local/bin/shfmt \
    && curl -fsSL -o /tmp/swift.tar.gz \
      "https://download.swift.org/swift-6.4.0-release/${swift_os}/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-ubuntu24.04${swift_suffix}.tar.gz" \
    && echo "${swift_sha}  /tmp/swift.tar.gz" | sha256sum --check --strict \
    && mkdir /opt/swift \
    && tar -xzf /tmp/swift.tar.gz -C /opt/swift --strip-components 1 \
    && rm /tmp/swift.tar.gz \
    && curl -fsSL -o /tmp/swiftlint.zip \
      "https://github.com/realm/SwiftLint/releases/download/0.63.2/swiftlint_linux_${arch}.zip" \
    && echo "${swiftlint_sha}  /tmp/swiftlint.zip" | sha256sum --check --strict \
    && unzip -q /tmp/swiftlint.zip swiftlint -d /usr/local/bin \
    && chmod 0755 /usr/local/bin/swiftlint \
    && rm /tmp/swiftlint.zip
ENV PATH=/opt/swift/usr/bin:${PATH}
# setup-bun uses ~/.bun/bin/bun when its version is the one that the
# workflow asks for, and then it downloads nothing.
COPY --from=bun --chown=1001:1001 /usr/local/bin/bun /home/runner/.bun/bin/bun
# The pools mount the easy-runners-cache volume here. A new volume takes
# the owner of this folder.
RUN install -d -o 1001 -g 1001 /cache
USER 1001:1001

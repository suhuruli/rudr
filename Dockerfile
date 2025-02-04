ARG BUILDER_IMAGE=rust:1.38
ARG BASE_IMAGE=debian:stretch-slim
ARG PACKAGE_NAME=rudr
FROM ${BUILDER_IMAGE} AS builder
WORKDIR /usr/src/rudr
RUN mkdir healthscope

COPY Cargo.toml .
COPY Cargo.lock .
COPY healthscope/Cargo.toml ./healthscope/

# Create dummy files to build the dependencies, cargo won't build without src/main.rs and src/lib.rs
# then remove Rudr fingerprint for following rebuild
RUN mkdir -p ./src/ && \
    echo 'fn main() {}' > ./src/main.rs && \
    echo '' > ./src/lib.rs && \
    mkdir -p ./healthscope/src/ && \
    echo 'fn main() {}' > ./healthscope/src/main.rs && \
    echo '' > ./healthscope/src/lib.rs
RUN cargo build --release && \
    cargo build --package healthscope --release && \
    rm -rf ./target/release/.fingerprint/rudr-* && \
    rm -rf ./target/release/.fingerprint/healthscope-*

# Build real binaries now
COPY ./src ./src
COPY ./healthscope/src ./healthscope/src
RUN cargo build --release
RUN cargo build --release --package healthscope

FROM ${BASE_IMAGE}
WORKDIR /usr/app
# kube-rs 0.6.1 need openssl 1.1.1 while using apt-get in debian:stretch-slim didn't work, so I have to compile from source here.
ENV OPENSSL_URL https://www.openssl.org/source/openssl-1.1.1d.tar.gz
ENV OPENSSL_SHA256 1e3a91bc1f9dfce01af26026f856e064eab4c8ee0a8f457b5ae30b40b8b711f2
ARG LD_LIBRARY_PATH=/opt/openssl-1.1.1/lib/
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH
RUN set -x \
&& savedAptMark="$(apt-mark showmanual)" \
&& apt-get update \
&& apt-get install -y --no-install-recommends \
		ca-certificates \
		build-essential \
		gcc \
		libc6-dev \
		liblua5.3-dev \
		libpcre3-dev \
		libssl-dev \
		make \
		wget \
		zlib1g-dev \
&& rm -rf /var/lib/apt/lists/* \
&& wget -O openssl.tar.gz "$OPENSSL_URL" \
&& echo "$OPENSSL_SHA256 *openssl.tar.gz" | sha256sum -c \
&& rm -rf /usr/src/openssl \
&& mkdir -p /usr/src/openssl \
&& tar -xzf openssl.tar.gz -C /usr/src/openssl \
&& rm openssl.tar.gz \
&& cd /usr/src/openssl/openssl-1.1.1d \
&& ./config --prefix=/opt/openssl-1.1.1 shared shared \
&& make \
&& make install \
&& makeOpts=' \
		TARGET=linux2628 \
		USE_LUA=1 LUA_INC=/usr/include/lua5.3 \
		USE_OPENSSL=1 \
		USE_PCRE=1 PCREDIR= \
		USE_ZLIB=1 \
        	SSL_LIB=/opt/openssl-1.1.1d/lib \
	        SSL_INC=/opt/openssl-1.1.1d/include \
	'\
&& apt-mark auto '.*' > /dev/null \
&& { [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; } \
&& find /usr/local -type f -executable -exec ldd '{}' ';' \
		| awk '/=>/ { print $(NF-1) }' \
		| sort -u \
		| xargs -r dpkg-query --search \
		| cut -d: -f1 \
		| sort -u \
		| xargs -r apt-mark manual \
&& apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false
ARG PACKAGE_NAME
COPY --from=builder /usr/src/rudr/target/release/${PACKAGE_NAME} .
ENV RUST_LOG ${PACKAGE_NAME}=info
RUN echo "./${PACKAGE_NAME}" > entrypoint.sh
RUN chmod 0755 entrypoint.sh
ENTRYPOINT ["/bin/sh", "./entrypoint.sh"]

# ---- User Container ---- 

FROM ubuntu:18.04 AS rudr-env

# Avoid warnings by switching to noninteractive
ENV DEBIAN_FRONTEND=noninteractive

# Install prereqs
RUN apt-get update && apt-get install -y apt-transport-https curl wget gnupg2 git procps

# Install k8s
RUN curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - \
    && echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | tee -a /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update \
    && apt-get install -y kubectl

# Install Helm 3
RUN wget https://get.helm.sh/helm-v3.0.0-rc.2-linux-amd64.tar.gz \
    && tar -zxvf helm-v3.0.0-rc.2-linux-amd64.tar.gz \
    && mv linux-amd64/helm /usr/local/bin/helm

# Install rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  -s -- -y \
    && apt install build-essential libssl-dev pkg-config -y \
    && echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc

# Switch back to dialog for any ad-hoc use of apt-get
ENV DEBIAN_FRONTEND=dialog

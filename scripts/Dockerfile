# The toolchain this library is built and tested with.
#
# There is no official Zig docker image, so this builds one from the release
# tarball published by ziglang.org, checked against the digest that release
# announced. The version is pinned because Zig is pre-1.0 and its standard
# library still changes shape between minor releases; see the README.
FROM alpine:3.22

ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

RUN apk add --no-cache ca-certificates \
    && apk add --no-cache --virtual .fetch curl tar xz \
    && curl -fsSL -o /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && apk del .fetch \
    && zig version

WORKDIR /work
ENTRYPOINT ["zig"]

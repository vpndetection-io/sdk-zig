#!/bin/bash

# Runs any zig command inside a pinned toolchain image, so the box needs no
# local Zig install.
#
#   ./scripts/zig.sh build test
#   ./scripts/zig.sh fmt --check src test build.zig
#   ./scripts/zig.sh version
#   ZIG_WORKDIR=integration ./scripts/zig.sh build test    # a nested package
#
# The image is built from the release tarball published by ziglang.org and
# checked against the digest that release announced; both the version and the
# digest are pinned here because Zig is pre-1.0 and its standard library still
# changes shape between minor releases. Overriding ZIG_VERSION means overriding
# ZIG_SHA256 as well, and the library is only claimed to build on the version
# below.
#
# Both caches live in a named docker VOLUME rather than in the working tree, so
# no .zig-cache or zig-out can end up in the repo or in a commit.

set -euo pipefail

cd "$(dirname "$0")/.."

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
ZIG_SHA256="${ZIG_SHA256:-70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00}"
ZIG_IMAGE="${ZIG_IMAGE:-vpndetection-sdk-zig:${ZIG_VERSION}}"
ZIG_CACHE_VOLUME="${ZIG_CACHE_VOLUME:-vpndetection-zig-cache}"
# A package nested inside the repo, relative to it. The whole repo is still
# mounted, so a path dependency on the parent resolves the way it would locally.
ZIG_WORKDIR="${ZIG_WORKDIR:-}"

if ! docker image inspect "$ZIG_IMAGE" >/dev/null 2>&1 ; then
    echo "==> building ${ZIG_IMAGE}" >&2
    docker build -t "$ZIG_IMAGE" \
        --build-arg "ZIG_VERSION=${ZIG_VERSION}" \
        --build-arg "ZIG_SHA256=${ZIG_SHA256}" \
        -f scripts/Dockerfile scripts >&2
fi

# Every exported VPNDETECTION_* variable is forwarded by NAME, rather than a list
# of them spelled out here. `-e NAME` with no `=` takes the value from this
# environment, so an unset one stays unset inside rather than arriving as the
# empty string. The integration suite owns which credentials it wants; this
# wrapper only has to not lose them, and adding a tier no longer means editing a
# toolchain script that has nothing to do with tiers.
env_args=()
for name in $(compgen -e | grep '^VPNDETECTION_' || true) ; do
    env_args+=(-e "$name")
done

exec docker run --rm -i \
    -v "$PWD:/work" \
    -v "${ZIG_CACHE_VOLUME}:/zig-cache" \
    -e ZIG_LOCAL_CACHE_DIR=/zig-cache/local \
    -e ZIG_GLOBAL_CACHE_DIR=/zig-cache/global \
    "${env_args[@]+"${env_args[@]}"}" \
    -w "/work${ZIG_WORKDIR:+/$ZIG_WORKDIR}" \
    "$ZIG_IMAGE" "$@"

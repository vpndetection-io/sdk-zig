#!/bin/bash

# Runs the integration suite against the library as PUBLISHED, which is the one
# thing the suite in ../test cannot check: it builds this working tree, so it
# stays green through a tag that was never pushed, a `paths` list that leaves a
# source file out of the package, or a module name a consumer cannot import.
#
#   ./scripts/run.sh
#   SDK_LOCAL_PATH=.. ./scripts/run.sh    # verify this suite before a tag exists
#                                         (relative to this package)
#
# Zig has no central registry, so a RELEASE IS A GIT TAG: `zig fetch` resolves
# one straight from the repository. That makes two conditions meaningful rather
# than failing, and each one skips with a reason instead:
#
#   1. No tag in the declared range exists. Before the first release there is
#      nothing published to test, and unlike an interpreted language a Zig test
#      naming a method that version does not have will not COMPILE, so this gate
#      covers the whole suite rather than one test.
#   2. A tier's staging key is missing or EMPTY. The unauthenticated tests still
#      run, and each tier without a key skips from inside the suite, so the skip
#      and its reason land in the test output rather than only here.
#
# Zig runs natively when the toolchain is present and inside the pinned image
# otherwise, so a dev box with no Zig and a CI runner both use this entry point.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO_URL="https://github.com/vpndetection-io/sdk-zig"
# The major this suite is written against. Read by hand rather than parsed out
# of a manifest: the gate has to run before anything is fetched or built.
RANGE_LOW="1.0.0"
RANGE_HIGH="2.0.0"

LOCAL_PATH="${SDK_LOCAL_PATH:-}"
manifestBackup=""

function main() {
    local versions="" newest=""
    if [ -n "$LOCAL_PATH" ] ; then
        echo "==> LOCAL: building against ${LOCAL_PATH}, NOT the published library."
        echo "==> This verifies the suite, and proves nothing about a release."
    else
        versions="$(publishedVersions)"
        if [ -z "$versions" ] ; then
            skip "no ${RANGE_LOW} <= tag < ${RANGE_HIGH} exists at ${REPO_URL}," \
                "so there is no published artifact to test"
            return 0
        fi
        newest="$(printf '%s\n' "$versions" | sort -V | tail -1)"
        echo "==> ${REPO_URL} publishes ${versions//$'\n'/, } within [${RANGE_LOW}, ${RANGE_HIGH})"
    fi

    reportTiers

    # The manifest is rewritten for the run and put back afterwards, so a daily
    # run keeps testing whatever is newest instead of pinning the version
    # somebody happened to commit, and a local run leaves no diff behind. The
    # backup path is a global: an EXIT trap runs after main has returned, so a
    # local would be out of scope by the time it fires.
    manifestBackup="$(mktemp)"
    cp build.zig.zon "$manifestBackup"
    trap restoreManifest EXIT

    if [ -n "$LOCAL_PATH" ] ; then
        saveLocalDependency
    else
        zigRun fetch --save=vpndetection "git+${REPO_URL}#v${newest}"
        assertFromATag "$newest"
    fi

    zigRun build test
}

# Every tag the repository serves inside the declared range, which is exactly
# what `zig fetch` would resolve against: it speaks git itself rather than going
# through a registry. A repo with no matching tag and one with no tags at all
# mean the same thing here.
function publishedVersions() {
    local refs tag
    refs="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null || true)"
    # Not a pipeline: a `while` whose last iteration skips a tag exits non-zero,
    # which `set -e` would read as the lookup itself having failed.
    while read -r tag ; do
        if [ -n "$tag" ] && inRange "$tag" ; then
            echo "$tag"
        fi
    done < <(printf '%s\n' "$refs" | sed -n 's#.*refs/tags/v\{0,1\}\([0-9]\+\.[0-9]\+\.[0-9]\+\)$#\1#p')
    return 0
}

function inRange() {
    local tag="$1" lowest highest
    lowest="$(printf '%s\n%s\n' "$tag" "$RANGE_LOW" | sort -V | head -1)"
    highest="$(printf '%s\n%s\n' "$tag" "$RANGE_HIGH" | sort -V | head -1)"
    [ "$lowest" = "$RANGE_LOW" ] && [ "$highest" = "$tag" ] && [ "$tag" != "$RANGE_HIGH" ]
}

# The suite is worthless if the build handed it the working tree, and that
# failure is SILENT: every test passes, against the wrong code. A path
# dependency carries no hash and names no tag, so a url plus a hash naming the
# tag we asked for is the proof that `zig fetch` went to the network.
function assertFromATag() {
    local want="$1"
    if grep -qE '\.path[[:space:]]*=' build.zig.zon ; then
        echo "FAILED: build.zig.zon carries a path dependency, so the tests would run" \
            "against a checkout rather than against the release" >&2
        exit 1
    fi
    # `zig fetch --save' does not store the url it was handed: it rewrites it to
    # `?ref=<tag>#<commit>', recording both the tag asked for and the commit that
    # tag resolved to. Matching the `#v<tag>' form that went IN therefore never
    # matches, and because no tag existed while this was written, the gate was
    # only ever seen taking its skip path. A gate seen only skipping is not a
    # gate; the published path has to be exercised before the first release.
    if ! grep -qF "git+${REPO_URL}?ref=v${want}#" build.zig.zon ; then
        echo "FAILED: build.zig.zon does not name ${REPO_URL} at v${want}" >&2
        exit 1
    fi
    if ! grep -qE '\.hash[[:space:]]*=' build.zig.zon ; then
        echo "FAILED: the dependency carries no hash, so nothing pins what was fetched" >&2
        exit 1
    fi
    echo "==> resolved sdk-zig v${want} from ${REPO_URL}"
}

# Only ever reached through SDK_LOCAL_PATH, and it cannot pass unnoticed: the
# gate above refuses a path dependency, and this branch prints what it is.
#
# Kept RELATIVE to this package, because the same manifest is read natively and
# inside the toolchain image, where the repository is mounted somewhere else.
function saveLocalDependency() {
    python3 - "$LOCAL_PATH" <<'PY'
import re, sys
target = sys.argv[1]
manifest = open("build.zig.zon").read()
manifest = re.sub(
    r"\.dependencies = \.\{\}",
    '.dependencies = .{\n        .vpndetection = .{ .path = "%s" },\n    }' % target,
    manifest,
    count=1,
)
open("build.zig.zon", "w").write(manifest)
PY
}

# Names only, never values: these logs are public.
function reportTiers() {
    local present=() absent=() secret
    for secret in VPNDETECTION_STAGING_KEY_FREE VPNDETECTION_STAGING_KEY_STARTER \
        VPNDETECTION_STAGING_KEY_SCALE VPNDETECTION_STAGING_KEY_MAX ; do
        # Empty counts as absent: CI interpolates a secret that does not exist to
        # an empty string, so the variable is SET and a plain unset check never
        # fires, while an empty key is sent as no key at all.
        if [ -n "${!secret:-}" ] ; then
            present+=("$secret")
        else
            absent+=("$secret")
        fi
    done
    echo "==> tiers with a key: ${present[*]:-none}"
    if [ "${#absent[@]}" -gt 0 ] ; then
        notice "no staging key for ${absent[*]}: those tiers skip from inside the suite"
    fi
}

function zigRun() {
    echo "==> zig $*"
    if command -v zig >/dev/null 2>&1 ; then
        zig "$@"
        return 0
    fi
    ZIG_WORKDIR=integration ../scripts/zig.sh "$@"
}

function restoreManifest() {
    if [ -n "$manifestBackup" ] ; then
        mv -f "$manifestBackup" build.zig.zon
    fi
}

function skip() {
    echo "==> SKIPPED: $*"
    notice "Integration suite skipped: $*"
}

# Surfaced on the workflow run itself, so a skip is visible without opening the
# log and reading to the end of it.
function notice() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ] ; then
        echo "::notice title=Integration::$*"
    fi
}

main "$@"

#!/bin/bash

# Checks the hand-written lookup model against the pinned OpenAPI spec.
#
# Nothing generates this client, so the response model is kept in step by hand
# and this is what catches a spec that moved: a property added to
# LookupResponse, one removed, or one whose optionality changed. Run it after
# scripts/download-spec.sh, and edit src/lookup.zig until it passes.
#
# Only LookupResponse is checked. It is the one shape where absent-versus-false
# carries meaning, so a drift there is a wrong ANSWER rather than a missing
# convenience.

set -euo pipefail

cd "$(dirname "$0")/.."

SPEC="${SPEC:-spec/openapi.yaml}"
MODEL="${MODEL:-src/lookup.zig}"

# Property names, and the required list, from the LookupResponse schema. Schema
# names sit at four spaces, their keys at six, and property names at eight.
function spec_members() {
    awk '
        /^    LookupResponse:/ { in_schema = 1; next }
        in_schema && /^    [A-Za-z]/ { in_schema = 0 }
        in_schema && /^      required:/ { mode = "required"; next }
        in_schema && /^      properties:/ { mode = "properties"; next }
        in_schema && /^      [a-z]/ { mode = "" }
        in_schema && mode == "required" && /^        - / { required[$2] = 1 }
        in_schema && mode == "properties" && /^        [a-z_]+:/ {
            name = $1
            sub(/:$/, "", name)
            properties[name] = 1
        }
        END {
            for (name in properties) {
                print name (name in required ? " required" : "")
            }
        }
    ' "$SPEC" | sort -u
}

# The same members as the Answer struct declares them. A field with a default is
# optional; one without is required, which is what makes a malformed answer an
# error rather than a zero value.
function model_members() {
    awk '
        /^pub const Answer = struct \{/ { inside = 1; next }
        inside && /^\};/ { inside = 0 }
        inside && /^    [a-z_@"]+:/ {
            name = $1
            sub(/:$/, "", name)
            gsub(/[@"]/, "", name)
            print name ($0 ~ / = / ? "" : " required")
        }
    ' "$MODEL" | sort -u
}

spec="$(spec_members)"
model="$(model_members)"

if [ "$spec" = "$model" ]; then
    echo "==> src/lookup.zig matches ${SPEC}'s LookupResponse ($(echo "$spec" | wc -l) members)"
    exit 0
fi

echo "==> DRIFT between ${SPEC} and ${MODEL}" >&2
echo "    < spec only, > model only ('required' means no default)" >&2
diff <(echo "$spec") <(echo "$model") | grep -E '^[<>]' >&2
exit 1

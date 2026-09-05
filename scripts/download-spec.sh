#!/bin/bash

# Refreshes the pinned OpenAPI spec from the published one.
#
# The copy in spec/ is what the response model is written against, so a build
# stays reproducible and offline and the diff shows exactly which spec version
# the client was checked against. Run this deliberately, then run
# scripts/check-spec.sh and commit the spec change alongside whatever the model
# needed, so a reviewer sees both.

set -euo pipefail

cd "$(dirname "$0")/.."

SPEC_URL="${SPEC_URL:-https://s3.internetdata.io/internetdata-public/openapi/openapi.yaml}"

curl -fsS "$SPEC_URL" -o spec/openapi.yaml
echo "spec/openapi.yaml <- ${SPEC_URL}"
grep -m1 '^  version:' spec/openapi.yaml

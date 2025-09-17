#!/bin/bash
set -euo pipefail

echo "--- CodeQL Security Analysis"

# Create CodeQL database
codeql database create codeql-db \
  --language=go \
  --source-root=. \
  --command="go build ./..."

# Analyze database
codeql database analyze codeql-db codeql/go-queries \
  --format=sarif-latest \
  --output=codeql-results.sarif

# Upload artifact and verify
if [ -f "codeql-results.sarif" ]; then
  buildkite-agent artifact upload codeql-results.sarif
  echo "CodeQL analysis complete - results saved to codeql-results.sarif"
else
  echo "CodeQL analysis failed"
  exit 1
fi
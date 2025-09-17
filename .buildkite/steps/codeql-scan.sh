#!/bin/bash
set -euo pipefail

echo "--- CodeQL Security Analysis"

codeql database create codeql-db \
  --language=go \
  --source-root=. \
  --command="go build ./..."

codeql database analyze codeql-db codeql/go-queries \
  --format=sarif-latest \
  --output=codeql-results.sarif

# Verify file exists, then upload as artifact
if [ -f "codeql-results.sarif" ]; then
  buildkite-agent artifact upload codeql-results.sarif
  echo "CodeQL analysis complete - results saved to codeql-results.sarif"
else
  echo "CodeQL analysis failed"
  exit 1
fi

# Upload to Github
echo "--- Uploading results to Github..."
if GH_TOKEN=$(buildkite-agent secret get GH_TOKEN 2>/dev/null); then
  echo "Github token found, attempting upload..."
  
  # Prepare SARIF data (gzip + base64)
  SARIF_DATA=$(gzip -c codeql-results.sarif | base64 -w0)
  
  # Get repo info from Buildkite environment variables, extract repo owner and name
  REPO_PATH=$(echo "${BUILDKITE_REPO}" | sed 's|.*github\.com[:/]||' | sed 's|\.git$||')
  REPO_OWNER=${REPO_PATH%/*}
  REPO_NAME=${REPO_PATH##*/}

  if [ "${BUILDKITE_PULL_REQUEST:-false}" != "false" ]; then
    REF="refs/pull/${BUILDKITE_PULL_REQUEST}/head"
  else
    REF="refs/heads/${BUILDKITE_BRANCH}"
  fi
  
  echo "Uploading to ${REPO_OWNER}/${REPO_NAME} (${BUILDKITE_COMMIT}) on ${REF}"

  if ! curl -L \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/code-scanning/sarifs" \
    -d "{
      \"commit_sha\": \"${BUILDKITE_COMMIT}\",
      \"ref\": \"${REF}\",
      \"sarif\": \"${SARIF_DATA}\"
    }"; then
    echo "❌ Upload to GitHub failed!"
  else
    echo "✅ Upload successful! Check GitHub Security tab for results."
  fi

else
  echo "⚠️  No GitHub token found - skipping upload to GitHub"
  echo "Set GH_TOKEN secret in Buildkite to enable GitHub integration"
fi

# Fetch SBOM
echo "--- Fetching SBOM from GitHub API..."
SBOM_FILE="sbom.json"

if curl -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/dependency-graph/sbom" \
  -o "${SBOM_FILE}"; then

  echo "SBOM fetched successfully, uploading as Buildkite artifact..."
  buildkite-agent artifact upload "${SBOM_FILE}"

else
  echo "⚠️ Failed to fetch SBOM from GitHub API"
fi
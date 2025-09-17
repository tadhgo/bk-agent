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

# Upload to Github and fetch SBOM
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

  # Fetch SBOM
  echo "--- Fetching SBOM from GitHub API..."
  SBOM_FILE="sbom.json"

  if ! curl -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/dependency-graph/sbom" \
    -o "${SBOM_FILE}"; then
    echo "⚠️ Failed to fetch SBOM from GitHub API"
  else
    echo "✅ SBOM fetched successfully, uploading as Buildkite artifact..."
    buildkite-agent artifact upload "${SBOM_FILE}"
    echo "--- Analyzing SBOM..."
    
    # Extract metrics
    TOTAL_DEPS=$(jq '.sbom.packages | length' sbom.json)
    
    # Count packages by ecosystem
    ECOSYSTEM_DATA=$(jq -r '.sbom.packages[].externalRefs[]? 
    | select(.referenceType=="purl") 
    | .referenceLocator 
    | split(":")[1]' sbom.json | sort | uniq -c | sort -nr)
    
    # License analysis
    LICENSE_DATA=$(jq -r '.sbom.packages[]
    | select(.licenseConcluded and .licenseConcluded != "NOASSERTION")
    | .licenseConcluded' sbom.json | sort | uniq -c | sort -nr)
    
    # Dependencies with copyright info
    WITH_COPYRIGHT=$(jq '.sbom.packages 
    | map(select(.copyrightText and .copyrightText != "")) 
    | length' sbom.json)
    
    # Get specific counts
    GO_COUNT=$(echo "$ECOSYSTEM_DATA" | grep golang | awk '{print $1}' || echo "0")
    RUBY_COUNT=$(echo "$ECOSYSTEM_DATA" | grep gem | awk '{print $1}' || echo "0")
    
    # Create SBOM annotation
    cat > sbom_annotation.md << EOF
## 📊 SBOM Analysis Results

### Overview
| Metric | Value |
|--------|-------|
| **Total Dependencies** | ${TOTAL_DEPS} |
| **Go Modules** | ${GO_COUNT} |
| **Ruby Gems** | ${RUBY_COUNT} |
| **With Copyright** | ${WITH_COPYRIGHT} |

### Ecosystem Breakdown
\`\`\`
$(echo "$ECOSYSTEM_DATA" | head -5)
\`\`\`

### License Distribution
\`\`\`
$(echo "$LICENSE_DATA" | head -5)
\`\`\`

---
📦 Full SBOM available in build artifacts
EOF

    # Upload annotation
    buildkite-agent annotate --context "sbom-analysis" --style "info" < sbom_annotation.md
    
    echo "✅ SBOM analysis complete - ${TOTAL_DEPS} dependencies analyzed"
  fi

else
  echo "⚠️  No GitHub token found - skipping upload to GitHub and SBOM fetch"
  echo "Set GH_TOKEN secret in Buildkite to enable GitHub integration"
fi
#!/usr/bin/env bash
set -euo pipefail

# End-to-end test for model tool format and fallback fixes.
# Tests each model with a tool-containing request to verify:
#   - No "Unknown server-tool shorthand" 400 errors
#   - No temperature constraint violations
#   - All Go provider models work through the transform path
#
# Usage:
#   source .env && ./scripts/e2e-test.sh [--build]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Config ---
PORT="${OC_GO_CC_PORT:-3457}"
HOST="${OC_GO_CC_HOST:-127.0.0.1}"
BASE_URL="http://${HOST}:${PORT}"
TIMEOUT_SEC=60
pass=0
fail=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
	echo "=== Cleaning up ==="
	./bin/oc-go-cc stop 2>/dev/null || true
	sleep 1
	rm -f ~/.config/oc-go-cc/oc-go-cc.pid
}
trap cleanup EXIT

# --- Build ---
if [ "${1:-}" = "--skip-build" ]; then
	echo -e "${YELLOW}Skipping build...${NC}"
else
	echo "=== Building oc-go-cc ==="
	make build
	echo ""
fi

# --- Source .env (must be done BEFORE start) ---
if [ -f .env ]; then
	set -a
	# shellcheck disable=SC1091
	source .env
	set +a
fi

if [ -z "${OC_GO_CC_API_KEY:-}" ]; then
	echo -e "${RED}Error: OC_GO_CC_API_KEY not set. Create a .env file or export it.${NC}"
	exit 1
fi

# --- Start proxy ---
echo "=== Starting proxy on ${HOST}:${PORT} ==="
cleanup
./bin/oc-go-cc serve -b --port "$PORT" 2>&1
sleep 2

# Health check
if ! curl -sf "${BASE_URL}/health" > /dev/null 2>&1; then
	echo -e "${RED}Proxy failed to start${NC}"
	exit 1
fi
echo -e "${GREEN}Proxy is running${NC}"
echo ""

# --- Test helper ---
test_model() {
	local model=$1
	local label=$2

	echo -n "  [$label] ${model} ... "

	REQUEST_BODY=$(cat <<'JSON'
{
	"model": "MODEL_PLACEHOLDER",
	"tools": [
		{
			"type": "custom",
			"name": "read_file",
			"description": "Read a file from the filesystem",
			"input_schema": {
				"type": "object",
				"properties": {
					"path": {"type": "string"}
				}
			}
		}
	],
	"messages": [
		{
			"role": "user",
			"content": [
				{"type": "text", "text": "Say hello and nothing else"}
			]
		}
	],
	"max_tokens": 100,
	"stream": false
}
JSON
)
	REQUEST_BODY="${REQUEST_BODY//MODEL_PLACEHOLDER/$model}"

	HTTP_CODE=$(curl -s -o /tmp/oc-go-cc-e2e-response.json -w '%{http_code}' \
		-X POST "${BASE_URL}/v1/messages" \
		-H "Content-Type: application/json" \
		-H "x-api-key: ${OC_GO_CC_API_KEY}" \
		-d "$REQUEST_BODY" \
		--max-time "$TIMEOUT_SEC")

	if [ "$HTTP_CODE" = 200 ]; then
		# Extract the text response for verification
		TEXT=$(python3 -c "
import json
with open('/tmp/oc-go-cc-e2e-response.json') as f:
    d = json.load(f)
blocks = d.get('content', [])
for b in blocks:
    if b.get('type') == 'text':
        print(b.get('text', ''))
" 2>/dev/null)
		echo -e "${GREEN}PASS${NC} (200, response: \"${TEXT}\")"
		pass=$((pass + 1))
	else
		ERROR_MSG=$(head -c 300 /tmp/oc-go-cc-e2e-response.json 2>/dev/null || echo "")
		echo -e "${RED}FAIL${NC} (HTTP ${HTTP_CODE})"
		echo "    Response: ${ERROR_MSG}"
		fail=$((fail + 1))
	fi
}

# --- Test cases ---
echo "=== E2E Model Tests (with tools and custom type) ==="
echo ""

test_model "minimax-m3"       "Tools format fix (was 400)"
test_model "deepseek-v4-flash" "Baseline"
test_model "kimi-k2.7-code"   "Temperature fix (was 400)"
test_model "deepseek-v4-pro"  "Thinking model"
test_model "qwen3.7-plus"     "Go provider qwen"

echo ""
echo "=== Results ==="
echo -e "${GREEN}Passed: ${pass}${NC}"
echo -e "${RED}Failed: ${fail}${NC}"
echo ""

if [ "$fail" -gt 0 ]; then
	exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

# --- config: adjust to match your local test harness ---
# curl (on the host) talks to Tor directly on :3128
PROXY_URL="${PROXY_URL:-http://127.0.0.1:3128}"
# FlareSolverr runs in Docker, so it reaches the same Tor instance via host.docker.internal
FLARESOLVERR_PROXY_URL="${FLARESOLVERR_PROXY_URL:-http://host.docker.internal:3128}"
FLARESOLVERR_URL="${FLARESOLVERR_URL:-http://localhost:8191/v1}"
# page to solve for the cookie/UA pair — override if you want a specific one
SOLVE_URL="${SOLVE_URL:-https://www.ebay.co.uk/p/8075614479?iid=128039305415}"
OUT_CSV="${OUT_CSV:-./exit-ip-correlation-$(date +%s).csv}"

# product_id:item_id pairs — only entries from the supplied list that had a non-null ebay_product_id
PAIRS=(
  "8075614479:128039305415"   "6052767054:267750703421"   "15093985514:227466512574"
  "15075618721:178383873109"  "27088414069:178383870619"  "12052748744:128015976087"
  "17090829980:377402153183"  "19087474313:318694577993"  "27094021437:198554831097"
  "21094010280:227466508705"  "25093987238:227466510170"  "23052763787:318694578166"
  "19091003077:377402151500"  "20056691466:178383869678"  "25064256290:318694572994"
  "8062142921:800476461607"   "5052760172:278256901906"   "25075604310:188758309026"
  "17075612424:188758311126"  "28075625338:188758312190"
)

echo "Solving via FlareSolverr..." >&2
SOLVE=$(curl -s -X POST "$FLARESOLVERR_URL" \
  -H "Content-Type: application/json" \
  -d "{\"cmd\":\"request.get\",\"url\":\"${SOLVE_URL}\",\"maxTimeout\":60000,\"proxy\":{\"url\":\"${FLARESOLVERR_PROXY_URL}\"}}")

USER_AGENT=$(echo "$SOLVE" | jq -r '.solution.userAgent')
COOKIES=$(echo "$SOLVE" | jq -r '[.solution.cookies[] | "\(.name)=\(.value)"] | join("; ")')

if [[ -z "$USER_AGENT" || "$USER_AGENT" == "null" || -z "$COOKIES" ]]; then
  echo "FlareSolverr solve failed — raw response:" >&2
  echo "$SOLVE" >&2
  exit 1
fi
echo "Solved. UA: $USER_AGENT" >&2

echo "index,product_id,item_id,exit_ip_before,http_status,exit_ip_after,timestamp" > "$OUT_CSV"

get_exit_ip() {
  curl -s --max-time 10 \
    --proxy "$PROXY_URL" \
    https://check.torproject.org/api/ip \
    | grep -o '"IP":"[^"]*"' | cut -d'"' -f4 || echo "ERR"
}

i=0
for pair in "${PAIRS[@]}"; do
  i=$((i+1))
  product_id="${pair%%:*}"
  item_id="${pair##*:}"

  ip_before=$(get_exit_ip)

  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    --proxy "$PROXY_URL" \
    -H "Cookie: ${COOKIES}" \
    -A "$USER_AGENT" \
    "https://www.ebay.co.uk/p/${product_id}?iid=${item_id}" || echo "000")

  ip_after=$(get_exit_ip)

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "${i},${product_id},${item_id},${ip_before},${status},${ip_after},${ts}" | tee -a "$OUT_CSV"
done

echo
echo "Written to $OUT_CSV"
echo
echo "Quick correlation check:"
echo "  awk -F, 'NR>1 {print \$4, \$5}' \"$OUT_CSV\" | sort | uniq -c | sort -rn"
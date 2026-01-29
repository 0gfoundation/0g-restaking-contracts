#!/usr/bin/env bash

set -euo pipefail

# Configuration
INTERVAL=300 # 5 minutes
OUT_FILE="restaking_balances.json"
LOG_DIR="logs"

# API Endpoints
BALANCES_URL="http://127.0.0.1:3500/eth/v1/beacon/states/head/validator_balances"
VALIDATORS_URL="http://127.0.0.1:3500/eth/v1/beacon/states/head/validators"

# Custom parameters
ETH_RPC="https://your-eth-rpc"
# If left empty, errors will be saved to $LOG_DIR/errors_*.log
SLACK_WEBHOOK_URL="" 
NETWORK="mainnet"
MAX_JOBS=4

# Ensure the local logs directory exists
mkdir -p "$LOG_DIR"

while true; do
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting collection cycle..."

  # Fetch validator balances
  balances_json=$(curl -s "$BALANCES_URL")

  # Filter data for entries containing symbiotic_balance
  filtered_balances=$(echo "$balances_json" | jq '
    .data
    | map(select(.symbiotic_balance | length > 0))
    | map({
        index: .index,
        symbiotic_balance: .symbiotic_balance
      })
  ')

  # Handle empty result set
  if [ "$(echo "$filtered_balances" | jq 'length')" -eq 0 ]; then
    echo "[]" > "$OUT_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No restaking balances detected."
    sleep "$INTERVAL"
    continue
  fi

  # Fetch validator metadata for pubkey mapping
  validators_json=$(curl -s "$VALIDATORS_URL")
  index_to_pubkey=$(echo "$validators_json" | jq '
    .data
    | map({ key: .index, value: .validator.pubkey })
    | from_entries
  ')

  # Merge balances with pubkeys
  result=$(jq -n \
    --argjson balances "$filtered_balances" \
    --argjson pubkeys "$index_to_pubkey" '
    $balances
    | map({
        index: .index,
        pubkey: $pubkeys[.index],
        symbiotic_balance: .symbiotic_balance
      })
  ')

  echo "$result" > "$OUT_FILE"

  # ------------------------------------------------------------
  # Step 4: Run forge script checks and parse output
  # ------------------------------------------------------------

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running forge validations..."

  tmp_errors=$(mktemp)

  run_check() {
    local index="$1"
    local pubkey="$2"
    local collateral="$3"
    local amount="$4"

    # Execute forge without -q to capture full output
    # We use 2>&1 to merge stdout and stderr
    local output
    output=$(forge script script/deploy/Dev.s.sol \
      --sig "checkVault(bytes memory,address,uint256)" \
      "$pubkey" "$collateral" "$amount" \
      --rpc-url "$ETH_RPC" 2>&1) || true

    if echo "$output" | grep -q "Script ran successfully."; then
      # SUCCESS CASE: Extract logs after "== Logs =="
      local logs
      logs=$(echo "$output" | sed -n '/== Logs ==/,$p' | tail -n +2)
      
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS | Index: $index | Pubkey: ${pubkey:0:10}... | Collateral: $collateral"
      echo "    Logs: $logs"
    else
      # FAILURE CASE: Capture output and store in tmp_errors
      {
        echo "• Index: $index"
        echo "  Pubkey: $pubkey"
        echo "  Collateral: $collateral"
        echo "  Output Trace:"
        echo "$output"
        echo "--------------------------------------"
      } >> "$tmp_errors"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED  | Index: $index | Check error logs for details."
    fi
  }

  export -f run_check
  export ETH_RPC tmp_errors

  # Spawn parallel jobs
  echo "$result" | jq -r '
    .[] | . as $v | $v.symbiotic_balance[]
    | "\($v.index) \($v.pubkey) \(.collateral) \(.amount)"
  ' | while read -r index pubkey collateral amount; do
      run_check "$index" "$pubkey" "$collateral" "$amount" &

      while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do
        wait -n
      done
    done

  wait

  # ------------------------------------------------------------
  # Reporting
  # ------------------------------------------------------------
  if [ -s "$tmp_errors" ]; then
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sending Slack alerts..."
      slack_payload=$(jq -n --arg text "
:rotating_light: *${NETWORK} restaking checkVault failures detected*

\`\`\`
$(cat "$tmp_errors")
\`\`\`
" '{text: $text}')
      curl -s -X POST -H 'Content-Type: application/json' --data "$slack_payload" "$SLACK_WEBHOOK_URL" >/dev/null
    else
      TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
      LOCAL_LOG="$LOG_DIR/errors_$TIMESTAMP.log"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Saving errors to $LOCAL_LOG"
      cp "$tmp_errors" "$LOCAL_LOG"
    fi
  fi

  rm -f "$tmp_errors"

  sleep 15
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cycle complete. Waiting for $INTERVAL seconds..."
  sleep "$INTERVAL"
done
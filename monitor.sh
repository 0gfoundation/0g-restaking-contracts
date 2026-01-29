#!/usr/bin/env bash

set -euo pipefail

INTERVAL=300 # 5 minutes
OUT_FILE="restaking_balances.json"

BALANCES_URL="http://127.0.0.1:3500/eth/v1/beacon/states/head/validator_balances"
VALIDATORS_URL="http://127.0.0.1:3500/eth/v1/beacon/states/head/validators"

# Custom parameters
ETH_RPC="https://your-eth-rpc"
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
NETWORK="mainnet"

while true; do
  echo "[`date '+%Y-%m-%d %H:%M:%S'`] collecting restaking balances..."

  # Step 1: fetch validator_balances and extract entries with non-empty symbiotic_balance
  balances_json=$(curl -s "$BALANCES_URL")

  filtered_balances=$(echo "$balances_json" | jq '
    .data
    | map(select(.symbiotic_balance | length > 0))
    | map({
        index: .index,
        symbiotic_balance: .symbiotic_balance
      })
  ')

  if [ "$(echo "$filtered_balances" | jq 'length')" -eq 0 ]; then
    echo "[]" > "$OUT_FILE"
    sleep "$INTERVAL"
    continue
  fi

  # Step 2: fetch validators and build index -> pubkey mapping
  validators_json=$(curl -s "$VALIDATORS_URL")

  index_to_pubkey=$(echo "$validators_json" | jq '
    .data
    | map({ key: .index, value: .validator.pubkey })
    | from_entries
  ')

  # Step 3: merge results
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
  # Step 4: run forge script checks in parallel
  # ------------------------------------------------------------

  echo "[`date '+%Y-%m-%d %H:%M:%S'`] running forge checks..."

  tmp_errors=$(mktemp)

  echo "$result" | jq -c '.[] | . as $v | $v.symbiotic_balance[] | {
      index: $v.index,
      pubkey: $v.pubkey,
      collateral: .collateral,
      amount: .amount
  }' | parallel --halt never '
    index={1}
    pubkey={2}
    collateral={3}
    amount={4}

    err=$(forge script script/deploy/Dev.s.sol \
      --sig "checkVault(bytes memory,address,uint256)" \
      "$pubkey" "$collateral" "$amount" \
      --rpc-url "'"$ETH_RPC"'" \
      -q 2>&1 >/dev/null) || {
        cat <<EOF >> '"$tmp_errors"'
• index: '"$index"'
  pubkey: '"$pubkey"'
  collateral: '"$collateral"'
  error:
'"$err"'

EOF
      }
  ' ::: $(echo "$result" | jq -r '
      .[] | . as $v | $v.symbiotic_balance[]
      | "\($v.index) \($v.pubkey) \(.collateral) \(.amount)"
  ')

  # If errors exist, send to Slack
  if [ -s "$tmp_errors" ]; then
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] errors detected, sending to Slack..."

    slack_payload=$(jq -n --arg text "
:rotating_light: *${NETWORK} restaking checkVault failures detected*

\`\`\`
$(cat "$tmp_errors")
\`\`\`
" '{text: $text}')

    curl -s -X POST \
      -H 'Content-Type: application/json' \
      --data "$slack_payload" \
      "$SLACK_WEBHOOK_URL" >/dev/null
  fi

  rm -f "$tmp_errors"

  sleep "$INTERVAL"
done

#!/bin/bash

VERIFIER_KEY=""
CHAIN_ID=16602
if [ "$CHAIN_ID" = "16602" ] || [ "$CHAIN_ID" = "16661" ]; then
  JSON_FILE="deployments/rewarder-${CHAIN_ID}.json"
else
  JSON_FILE="deployments/zerogravity-${CHAIN_ID}.json"
fi

keys=$(jq -r 'keys[]' "$JSON_FILE")

for key in $keys; do
  value=$(jq -r --arg k "$key" '.[$k]' "$JSON_FILE")

  eval "$key=$value"

done

if [ "$CHAIN_ID" != "16661" ] && [ "$CHAIN_ID" != "16602" ]; then
  VERIFIER_URL="https://api.etherscan.io/v2/api"
  forge verify-contract $BaseMiddlewareReader BaseMiddlewareReader --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $OperatorBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $OperatorImpl ZeroGravityOperator --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $ZeroGravityFactory BeaconProxy --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $ZeroGravityFactoryBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $ZeroGravityFactoryImpl ZeroGravityFactory --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $ZeroGravityMiddleware BeaconProxy --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $ZeroGravityMiddlewareBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
  forge verify-contract $ZeroGravityMiddlewareImpl ZeroGravityMiddleware --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID --verifier-api-version v2
else
  if [ "$CHAIN_ID" = "16602" ]; then
    VERIFIER_URL="https://chainscan-galileo.0g.ai/open/api"
  elif [ "$CHAIN_ID" = "16661" ]; then
    VERIFIER_URL="https://chainscan.0g.ai/open/api"
  fi
  
  forge verify-contract $RestakingStates RestakingStates  --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RestakingStatesBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RestakingStatesImpl RestakingStates --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderFactory RewarderFactory --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderFactoryBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderFactoryImpl RewarderFactory --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderImpl Rewarder --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
fi
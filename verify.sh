#!/bin/bash

VERIFIER_KEY="00"
CHAIN_ID=16602

# Initialize JSON_FILES as an array
JSON_FILES=()

# Set JSON files based on chain ID
if [ "$CHAIN_ID" = "16602" ] || [ "$CHAIN_ID" = "16661" ]; then
  JSON_FILES+=("deployments/rewarder-${CHAIN_ID}.json")
  JSON_FILES+=("deployments/ascend-${CHAIN_ID}.json")
else
  JSON_FILES+=("deployments/zerogravity-${CHAIN_ID}.json")
fi

# Loop through each JSON file
for json_file in "${JSON_FILES[@]}"; do
  # Check if the file exists
  if [ -f "$json_file" ]; then
    echo "Processing file: $json_file"
    
    # Get all keys from the current JSON file
    keys=$(jq -r 'keys[]' "$json_file")
    
    # Loop through each key and set the variable
    for key in $keys; do
      value=$(jq -r --arg k "$key" '.[$k]' "$json_file")
      
      # Set the variable using the key and value
      eval "$key=$value"
      echo "Set $key=$value"
    done
  else
    echo "Warning: File $json_file not found, skipping."
  fi
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
  
  forge verify-contract $RestakingStates BeaconProxy  --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RestakingStatesBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RestakingStatesImpl RestakingStates --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderFactory BeaconProxy --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderFactoryBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderFactoryImpl RewarderFactory --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $RewarderImpl Rewarder --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  
  forge verify-contract $AscendRouter BeaconProxy --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $AscendRouterBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID
  forge verify-contract $AscendRouterImpl AscendRouter --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL --chain $CHAIN_ID


fi
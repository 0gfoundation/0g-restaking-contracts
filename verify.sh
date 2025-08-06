#!/bin/bash

CHAIN_ID=
JSON_FILE="deployments/zerogravity-${CHAIN_ID}.json"
VERIFIER_KEY=""
VERIFIER_URL=""

keys=$(jq -r 'keys[]' "$JSON_FILE")

for key in $keys; do
  value=$(jq -r --arg k "$key" '.[$k]' "$JSON_FILE")

  eval "$key=$value"

done

forge verify-contract $BaseMiddlewareReader BaseMiddlewareReader --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $OperatorBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $OperatorImpl ZeroGravityOperator --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $ZeroGravityFactory BeaconProxy --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $ZeroGravityFactoryBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $ZeroGravityFactoryImpl ZeroGravityFactory --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $ZeroGravityMiddleware BeaconProxy --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $ZeroGravityMiddlewareBeacon UpgradeableBeacon --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
forge verify-contract $ZeroGravityMiddlewareImpl ZeroGravityMiddleware --verifier custom --verifier-api-key $VERIFIER_KEY --verifier-url $VERIFIER_URL
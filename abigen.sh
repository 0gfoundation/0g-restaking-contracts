#!/bin/bash

set -e

mkdir -p abis
mkdir -p abigen

find out -type f -name "*.json" | while read -r json_path; do
    if [[ "$json_path" == out/build-info/* ]] || [[ "$json_path" == *".t.sol/"* ]]; then
        continue
    fi

    contract_file=$(basename "$json_path")
    contract_name="${contract_file%.json}"

    abi_path="abis/$contract_name.json"
    jq '.abi' "$json_path" > "$abi_path"
    echo "✅ ABI extracted: $abi_path"

    go_out="abigen/$contract_name.go"
    abigen --abi "$abi_path" --pkg "$contract_name" --out "$go_out"
    echo "📦 Go binding generated (no deploy): $go_out"
done

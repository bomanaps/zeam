#!/bin/bash
# set -e

currentDir=$(pwd)
scriptDir=$(dirname $0)

source "$(dirname $0)/parse-env.sh"
source "$(dirname $0)/set-up.sh"

popupTerminal="gnome-terminal --disable-factory --"

for item in "${spin_nodes[@]}"; do
  echo "spining $item..."

  execCmd="$scriptDir/../zig-out/bin/zeam node \
  --custom_genesis $configDir \
  --network_dir $configDir/$item \
  --data_dir $dataDir/$item \
  --node_key $item \
  --validator_config $validatorConfig"

  if [ ! -n "$inTerminal" ]
  then
    execCmd="$popupTerminal $execCmd"
  fi;

  echo "$execCmd"
  eval "$execCmd" &
done;
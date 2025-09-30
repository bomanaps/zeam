#!/bin/bash
# set -e

currentDir=$(pwd)
scriptDir=$(dirname $0)

source "$(dirname $0)/parse-env.sh"
source "$(dirname $0)/set-up.sh"

popupTerminal="gnome-terminal --disable-factory --"

for item in "${spin_nodes[@]}"; do
  echo "spining $item..."

  execCmd="../zig-out/bin/zeam node \
  --custom_genesis $configDir \
  --network_dir $configDir/$item \
  --db_path $dataDir/$item"

  if [ ! -n "$inTerminal" ]
  then
    execCmd="$popupTerminal $execCmd"
  fi;

  echo "$execCmd"
  eval "$execCmd" &
done;
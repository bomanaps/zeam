#!/bin/bash
# set -e

if [ -n "$NETWORK_DIR" ]
then
  echo "sourcing $scriptDir/$NETWORK_DIR/env.vars"
  configDir="$scriptDir/$NETWORK_DIR/genesis"
  dataDir="$scriptDir/$NETWORK_DIR/data"
else
  echo "set NETWORK_DIR env variable to run"
  exit
fi;

# TODO: check for presense of all required files by filenames on configDir
if [ ! -n "$(ls -A $configDir)" ]
then
  echo "no genesis config at path=$configDir, exiting."
  exit
fi;

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --node)
      node="$2"
      shift # past argument
      shift # past value
      ;;
    --validatorConfig)
      validatorConfig="$2"
      shift # past argument
      shift # past value
      ;;
    --freshStart)
      freshStart=true
      shift # past argument
      ;;
    --cleanData)
      cleanData=true
      shift # past argument
      ;;
    --inTerminal)
      inTerminal=true
      shift # past argument
      ;;
    *)    # unknown option
      shift # past argument
      ;;
  esac
done

# if no node has been assigned assume all nodes to be started
if [[ ! -n "$node" ]];
then
  echo "no node specified, exiting..."
  exit
fi;

if [ ! -n "$validatorConfig" ]
then
  echo "no external validator config provided, assuming genesis bootnode"
  validatorConfig="genesis_bootnode"
fi;

# ideally read config from validatorConfig and figure out all nodes in the array
# if validatorConfig is genesis bootnode then we read the genesis/validator_config.yaml for this
nodes=("zeam_0" "zeam_1")
spin_nodes=()

for item in "${nodes[@]}"; do
  if [ $node == $item ] || [ $node == "all" ]
  then
    node_present=true
    spin_nodes+=($item)
  fi;
done
if [ ! -n "$node_present" ] && [ node != "all" ]
then
  echo "invalid specified node, options =${nodes[@]} all, exiting."
  exit;
fi;

if [ -n "$freshStart" ]
then
  echo "starting from a fresh genesis time..."
  cleanData=true
fi;


echo "configDir = $configDir"
echo "dataDir = $dataDir"
echo "spin_nodes(s) = ${spin_nodes[@]}"
echo "freshStart = $freshStart"
echo "cleanData = $cleanData"
echo "inTerminal = $inTerminal"

# lean quickstart

A single command line quickstart to spin up lean node(s)

## Requirements

1. Shell terminal: Preferably linux especially if you want to pop out separate new terminals for node
2. Genesis configuration
3. Zeam Build (other clients to be supported soon)

## Scenarios

### Quickly startup two zeam nodes as a local devnet

```sh
NETWORK_DIR=local-devnet ./spin-node.sh --freshStart
```
  
## Args

1. `NETWORK_DIR` is an env to specify the network directory. Should have a `genesis` directory with genesis config. A `data` folder will be created inside this `NETWORK_DIR` if not already there.
2. `--freshStart` reset the genesis time in the `config.yaml` to now
3. `--inTerminal` if you don't want to pop out new terminals to run the nodes, else by default opens gnome terminals
4. `--node` specify which node you want to run, use `all` to run all the nodes in a single go
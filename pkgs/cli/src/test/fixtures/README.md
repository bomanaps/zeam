# Zeam Test Fixtures

This directory contains pre-configured fixtures for running two zeam nodes locally that can communicate and achieve finalization.

## Directory Structure

```
fixtures/
├── README.md              # This file
├── genisis/               # Genesis configuration for 2-node setup
│   ├── config.yaml        # Genesis and validator settings
│   ├── nodes.yaml         # Fixed ENRs for both nodes
│   ├── validators.yaml    # Validator assignment (zeam_0, zeam_1)
│   ├── node0/
│   │   └── key           # Fixed private key for node 0
│   └── node1/
│       └── key           # Fixed private key for node 1
├── config.yaml            # Alternative config (9 validators)
├── nodes.yaml             # Alternative ENRs (3 nodes)
├── validators.yaml        # Alternative validator assignment
└── validator-config.yaml  # Validator generation config
```

## Quick Start: Running Two Nodes

Follow these steps to run two zeam nodes from the repository root:

### Step 0: Generate Genesis Timestamp

```bash
GENESIS_TIME=$(date +%s)
echo "Genesis time: $GENESIS_TIME"
```

**Important:** Save this timestamp! You'll need to use the SAME value in both terminals.

### Step 1: Build the Project

```bash
zig build -Doptimize=ReleaseFast
```

### Step 2: Create Data Directories

```bash
mkdir -p data/test_node0 data/test_node1
```

### Step 3: Run Node 0 (Terminal 1)

Open a new terminal window and run:

```bash
./zig-out/bin/zeam node \
  --custom_genesis ./pkgs/cli/src/test/fixtures/genisis \
  --node_id 0 \
  --network_dir ./pkgs/cli/src/test/fixtures/genisis/node0 \
  --override_genesis_time $GENESIS_TIME \
  --db_path ./data/test_node0
```

Replace `$GENESIS_TIME` with the actual timestamp from Step 0.

### Step 4: Run Node 1 (Terminal 2)

Open another terminal window and run:

```bash
./zig-out/bin/zeam node \
  --custom_genesis ./pkgs/cli/src/test/fixtures/genisis \
  --node_id 1 \
  --network_dir ./pkgs/cli/src/test/fixtures/genisis/node1 \
  --override_genesis_time $GENESIS_TIME \
  --db_path ./data/test_node1
```

Use the **SAME** `$GENESIS_TIME` value from Step 0.

### Expected Behavior

Both nodes should:
- Start successfully and display the Zeam ASCII logo
- Discover each other as peers
- Begin producing blocks
- Exchange votes between validators
- Achieve justification and finalization

You'll see output like:
```
Latest Justified:   Slot     12 | Root: 0xc2c1742d996828815b6359a48cb3d404...
Latest Finalized:   Slot      9 | Root: 0xc51a79ed9a8eb78a695639e5599729...
```

## Configuration Details

### Genesis Setup (`genisis/`)

The `genisis/` directory contains a minimal 2-node, 3-validator setup:

**`config.yaml`:**
- `VALIDATOR_COUNT: 3` - Total of 3 validators
- `GENESIS_TIME: 1704085200` - Placeholder (overridden by `--override_genesis_time`)

**`validators.yaml`:**
- `zeam_0: [0]` - Node 0 controls validator index 0
- `zeam_1: [1, 2]` - Node 1 controls validator indices 1 and 2

With 3 validators, we need 2/3 (2 validators) to reach finalization.

**`nodes.yaml`:**
- Contains 2 fixed ENRs (Ethereum Node Records)
- Node 0: QUIC port 9000, IP 127.0.0.1
- Node 1: QUIC port 9001, IP 127.0.0.1

**Private Keys (`node0/key`, `node1/key`):**
- Fixed 64-character hex strings (no trailing newline)
- **Node 0:** `bdf953adc161873ba026330c56450453f582e3c4ee6cb713644794bcfdd85fe5`
- **Node 1:** `af27950128b49cda7e7bc9fcb7b0270f7a3945aa7543326f3bfdbd57d2a97a32`

## Recreating the Fixtures

If you need to recreate the `genisis/` directory from scratch, run these commands from the repository root:

```bash
# Create directory structure
mkdir -p pkgs/cli/src/test/fixtures/genisis/node0 pkgs/cli/src/test/fixtures/genisis/node1

# Create fixed private keys (64 hex chars, NO newline)
printf "bdf953adc161873ba026330c56450453f582e3c4ee6cb713644794bcfdd85fe5" > pkgs/cli/src/test/fixtures/genisis/node0/key
printf "af27950128b49cda7e7bc9fcb7b0270f7a3945aa7543326f3bfdbd57d2a97a32" > pkgs/cli/src/test/fixtures/genisis/node1/key

# Create config.yaml
cat > pkgs/cli/src/test/fixtures/genisis/config.yaml << 'EOF'
# Genesis Settings
GENESIS_TIME: 1704085200

# Validator Settings  
VALIDATOR_COUNT: 3
EOF

# Create nodes.yaml with fixed ENRs
cat > pkgs/cli/src/test/fixtures/genisis/nodes.yaml << 'EOF'
- enr:-IW4QCbghTYFhAE5qEfEGijkGp7e1dkqdNb_EiJFt7W0jSQxcBQ_DkoKYXW59LGfbn20GmRT-FGoSGfN58hiVS0_STaAgmlkgnY0gmlwhH8AAAGEcXVpY4IjKIlzZWNwMjU2azGhAhMMnGF1rmIPQ9tWgqfkNmvsG-aIyc9EJU5JFo3Tegys
- enr:-IW4QHcgN6JcdQX5mHEnJqEmeDiZfXTyFsAgOjqprNP1-5cYXLELqJtcKrmMvLNkkXXMy8SOTI90oTkCVY3yIEhR-G2AgmlkgnY0gmlwhH8AAAGEcXVpY4IjKYlzZWNwMjU2azGhA5_HplOwUZ8wpF4O3g4CBsjRMI6kQYT7ph5LkeKzLgTS
EOF

# Create validators.yaml
cat > pkgs/cli/src/test/fixtures/genisis/validators.yaml << 'EOF'
zeam_0:
  - 0
zeam_1:
  - 1
  - 2
EOF

# Verify
echo "=== Verification ==="
echo "Node 0 key length: $(wc -c < pkgs/cli/src/test/fixtures/genisis/node0/key) (should be 64)"
echo "Node 1 key length: $(wc -c < pkgs/cli/src/test/fixtures/genisis/node1/key) (should be 64)"
ls -la pkgs/cli/src/test/fixtures/genisis/
```

## Troubleshooting

### Nodes don't connect to each other

1. Ensure both nodes use the **same** `--override_genesis_time` value
2. Check that ports 9000 and 9001 are not in use: `lsof -i :9000` and `lsof -i :9001`
3. Verify the ENRs in `nodes.yaml` are correct

### "InvalidValidatorConfig" error

- Check that `validators.yaml` node names match the `node_id` parameter
- Ensure `VALIDATOR_COUNT` in `config.yaml` matches total validators in `validators.yaml`

### Finalization not happening

- You need at least 2/3 validators voting
- With the default setup (3 validators), both nodes must be running
- Check that both nodes are on the same slot number

### Clean restart

To start fresh:

```bash
rm -rf data/test_node0 data/test_node1
mkdir -p data/test_node0 data/test_node1
# Then run nodes with a new GENESIS_TIME
```

## Important Notes

- **Fixed Configuration:** All keys, ENRs, and settings are pre-configured and fixed. No random generation needed.
- **Same Timestamp:** Both nodes MUST use the exact same `--override_genesis_time` value
- **Separate Terminals:** Run each node in its own terminal window to see live output
- **Network Isolation:** This setup uses localhost (127.0.0.1) only, suitable for local testing
- **Data Directories:** Each node needs its own database path to avoid conflicts

## Command Summary

For quick reference, here are the commands assuming `GENESIS_TIME=1759210782`:

**Terminal 1 (Node 0):**
```bash
cd /Users/mercynaps/zeam
./zig-out/bin/zeam node --custom_genesis ./pkgs/cli/src/test/fixtures/genisis --node_id 0 --network_dir ./pkgs/cli/src/test/fixtures/genisis/node0 --override_genesis_time 1759210782 --db_path ./data/test_node0
```

**Terminal 2 (Node 1):**
```bash
cd /Users/mercynaps/zeam
./zig-out/bin/zeam node --custom_genesis ./pkgs/cli/src/test/fixtures/genisis --node_id 1 --network_dir ./pkgs/cli/src/test/fixtures/genisis/node1 --override_genesis_time 1759210782 --db_path ./data/test_node1
```

Replace `1759210782` with your actual `GENESIS_TIME` from `date +%s`.

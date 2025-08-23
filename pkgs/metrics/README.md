# Zeam Metrics Package

## Overview

This package provides Prometheus metrics for the `zeam` application. It allows for instrumentation of the code to expose key performance indicators and health statistics.

The primary components are:
- A metrics service implemented in `src/lib.zig`.
- The underlying Prometheus client library: [karlseguin/metrics.zig](https://github.com/karlseguin/metrics.zig).

## Metrics Exposed

The following metrics are currently available:

- **`chain_onblock_duration_seconds`** (Histogram)
  - **Description**: Measures the time taken to process a block within the `chain.onBlock` function.
  - **Labels**: None.

## How It Works

The metrics system is initialized at application startup in `pkgs/cli/src/main.zig`. 

1.  `metrics.init()` is called once to set up the metric registry and define all histograms, counters, and gauges.
2.  `metrics.startListener()` is called to spawn a background thread that runs an HTTP server.
3.  This server listens on port `9667` and exposes all registered metrics at the `/metrics` endpoint, making them available for a Prometheus server to scrape.

## Running for Visualization (Local Setup)

Here is a complete guide to running the `zeam` node and visualizing its metrics in Grafana.

### Prerequisites

You must have Docker installed.

### 1. Build the Application

From the root of the `zeam` repository, compile the application:

```sh
./zig-linux-x86_64-0.14.0/zig build
```

### 2. Configure and Run Prometheus

The repository includes a `prometheus.yml` file configured to scrape both the Prometheus server itself and the `zeam` application. 

Run the Prometheus Docker container using **host networking** to allow it to connect to the `zeam` application:

```sh
docker run -d --name prometheus --network="host" -v "$(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml" prom/prometheus --config.file=/etc/prometheus/prometheus.yml
```

### 3. Configure and Run Grafana

Run the Grafana Docker container, also on the host network:

```sh
docker run -d --name grafana --network="host" grafana/grafana
```

- Access Grafana at [http://localhost:3000](http://localhost:3000) (default login: `admin`/`admin`).
- Add Prometheus as a data source:
  - **URL**: `http://localhost:9090`
  - Click "Save & Test".

### 4. Run the Zeam Application

Start the `zeam` node in the background. We recommend redirecting its output to a log file.

```sh
./zig-out/bin/zeam beam > zeam.log 2>&1 &
```

### 5. Verify and Visualize

1.  **Check Prometheus Targets**: Open the Prometheus UI at [http://localhost:9090/targets](http://localhost:9090/targets). Both the `zeam` and `zeam_app` jobs should be **UP**.
2.  **Build a Grafana Dashboard**: Create a new dashboard and panel. Use a query like the following to visualize the 95th percentile of block processing time:
    ```promql
    histogram_quantile(0.95, sum(rate(chain_onblock_duration_seconds_bucket[5m])) by (le))
    ```

## Adding New Metrics

To add a new metric, follow the existing pattern:

1.  **Declare it**: Add a new global variable for your metric in `pkgs/metrics/src/lib.zig`.
2.  **Initialize it**: In the `init()` function in `lib.zig`, initialize the metric with its name, help text, and any labels or buckets.
3.  **Use it**: Import the metrics package in your application code and record observations (e.g., `metrics.my_new_metric.observe(value)`).

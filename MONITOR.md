# Dry-run monitor

The monitoring loop runs as process `cex-dry-run-monitor` from `scripts/monitor-dry-run.sh`, with an internal restart-on-failure loop. Each cycle runs `scripts/check-dry-run.sh` every 600 seconds and updates `/tmp/cex-dry-run-monitor.heartbeat`; output is retained in `/tmp/cex-dry-run-monitor.log`. A read-only liveness check may inspect the heartbeat mtime and process command line.

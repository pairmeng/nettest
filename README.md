# Global Network Quality Test

A simple one-click network quality testing script for VPS and international routes.

## Features

* Ping test
* MTR route analysis
* Traceroute
* TCP bandwidth test
* UDP jitter/loss test
* HTTP real-world speed test
* Loop mode for peak-hour monitoring

## Install

```bash
curl -fL -o nettest.sh https://raw.githubusercontent.com/pairmeng/nettest/main/nettest.sh
chmod +x nettest.sh
```

## Server Mode

```bash
./nettest.sh server
```

## Client Mode

```bash
./nettest.sh client IP
```

TCP and UDP bandwidth tests require `iperf3` running on the target host.
If the remote `iperf3` service listens on another host or port, set:

```bash
IPERF_SERVER=HOST IPERF_PORT=5201 ./nettest.sh client IP
```

## Loop Monitoring

```bash
./nettest.sh loop IP
```

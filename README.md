# Global Network Quality Test

A simple one-click network quality testing script for VPS and international routes.

## Features

* Ping test
* MTR route analysis
* Traceroute
* TCP bandwidth test
* UDP jitter/loss test
* HTTP real-world speed test
* HTML report export
* Loop mode for peak-hour monitoring

## One-Step Run

```bash
curl -fL https://raw.githubusercontent.com/pairmeng/nettest/main/nettest.sh | bash -s -- YOUR_SERVER_IP
```

This downloads the script, installs missing dependencies, runs the selected tests, and writes an HTML report to `./logs/`.

## Server Mode

```bash
./nettest.sh server
```

One-step install + start:

```bash
curl -fL https://raw.githubusercontent.com/pairmeng/nettest/main/nettest.sh | bash -s -- server
```

## Client Mode

```bash
./nettest.sh client IP
```

You can also run the client in one step:

```bash
curl -fL https://raw.githubusercontent.com/pairmeng/nettest/main/nettest.sh | bash -s -- YOUR_SERVER_IP
```

The HTML report is saved as `./logs/nettest_<target>_<timestamp>.html`.

TCP and UDP bandwidth tests require `iperf3` running on the target host.
If the remote `iperf3` service listens on another host or port, set:

```bash
IPERF_SERVER=HOST IPERF_PORT=5201 ./nettest.sh client IP
```

## Loop Monitoring

```bash
./nettest.sh loop IP
```

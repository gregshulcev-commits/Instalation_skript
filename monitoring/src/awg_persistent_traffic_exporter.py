#!/usr/bin/env python3
"""
Persistent traffic overlay exporter for AmneziaWG / WireGuard metrics.

It reads prometheus_wireguard_exporter's raw counters and exposes monotonic
counters that survive exporter restarts and WireGuard interface counter resets.
Only Python standard library is used.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, MutableMapping, Optional, Tuple

try:
    import fcntl  # type: ignore
except ImportError:  # pragma: no cover - Linux target has fcntl.
    fcntl = None

RAW_TO_PERSISTENT = {
    "wireguard_received_bytes_total": "awg_persistent_received_bytes_total",
    "wireguard_sent_bytes_total": "awg_persistent_sent_bytes_total",
}

HELP_TEXT = {
    "awg_persistent_received_bytes_total": "Persisted bytes received from the peer, adjusted for raw counter resets.",
    "awg_persistent_sent_bytes_total": "Persisted bytes sent to the peer, adjusted for raw counter resets.",
}

SAMPLE_RE = re.compile(
    r"^(wireguard_(?:received|sent)_bytes_total)\{(.*)\}\s+([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*$"
)


@dataclass(frozen=True)
class RawSample:
    raw_metric: str
    persistent_metric: str
    labels: Dict[str, str]
    value: float

    @property
    def direction(self) -> str:
        return "rx" if self.raw_metric == "wireguard_received_bytes_total" else "tx"

    @property
    def stable_key(self) -> str:
        interface = self.labels.get("interface", "")
        public_key = self.labels.get("public_key", "")
        allowed_ips = self.labels.get("allowed_ips", "")
        if public_key:
            peer_id = public_key
        else:
            peer_id = allowed_ips
        return f"{self.direction}|{interface}|{peer_id}"


def parse_labels(raw: str) -> Dict[str, str]:
    labels: Dict[str, str] = {}
    i = 0
    n = len(raw)
    while i < n:
        while i < n and raw[i] in " \t,":
            i += 1
        if i >= n:
            break
        start = i
        while i < n and raw[i] != "=":
            i += 1
        if i >= n:
            break
        key = raw[start:i].strip()
        i += 1
        if i >= n or raw[i] != '"':
            break
        i += 1
        value_chars: List[str] = []
        while i < n:
            ch = raw[i]
            if ch == "\\" and i + 1 < n:
                nxt = raw[i + 1]
                if nxt == "n":
                    value_chars.append("\n")
                else:
                    value_chars.append(nxt)
                i += 2
                continue
            if ch == '"':
                i += 1
                break
            value_chars.append(ch)
            i += 1
        if key:
            labels[key] = "".join(value_chars)
        while i < n and raw[i] not in ",":
            i += 1
        if i < n and raw[i] == ",":
            i += 1
    return labels


def escape_label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def format_labels(labels: Mapping[str, str]) -> str:
    preferred = ["interface", "friendly_name", "public_key", "allowed_ips", "allowed_ip_0", "allowed_subnet_0"]
    keys: List[str] = []
    for key in preferred:
        if key in labels and key not in keys:
            keys.append(key)
    for key in sorted(labels):
        if key not in keys:
            keys.append(key)
    return ",".join(f'{key}="{escape_label_value(str(labels[key]))}"' for key in keys)


def parse_wireguard_samples(text: str) -> List[RawSample]:
    samples: List[RawSample] = []
    for line in text.splitlines():
        match = SAMPLE_RE.match(line.strip())
        if not match:
            continue
        raw_metric, labels_raw, value_raw = match.groups()
        persistent_metric = RAW_TO_PERSISTENT[raw_metric]
        labels = parse_labels(labels_raw)
        try:
            value = float(value_raw)
        except ValueError:
            continue
        if value < 0:
            continue
        samples.append(RawSample(raw_metric, persistent_metric, labels, value))
    return samples


def empty_state() -> Dict[str, object]:
    return {
        "version": 1,
        "last_raw": {},
        "totals": {},
        "labels": {},
        "metrics": {},
        "updated_at": 0,
    }


def load_state(path: Path) -> Dict[str, object]:
    if not path.exists():
        return empty_state()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return empty_state()
    if not isinstance(data, dict):
        return empty_state()
    state = empty_state()
    state.update(data)
    for key in ["last_raw", "totals", "labels", "metrics"]:
        if not isinstance(state.get(key), dict):
            state[key] = {}
    return state


def save_state(path: Path, state: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, ensure_ascii=False, sort_keys=True, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def update_state_with_samples(state: MutableMapping[str, object], samples: Iterable[RawSample], now: Optional[float] = None) -> None:
    last_raw: MutableMapping[str, float] = state.setdefault("last_raw", {})  # type: ignore[assignment]
    totals: MutableMapping[str, float] = state.setdefault("totals", {})  # type: ignore[assignment]
    labels_store: MutableMapping[str, Dict[str, str]] = state.setdefault("labels", {})  # type: ignore[assignment]
    metrics_store: MutableMapping[str, str] = state.setdefault("metrics", {})  # type: ignore[assignment]

    for sample in samples:
        key = sample.stable_key
        current = float(sample.value)
        previous = last_raw.get(key)
        total = float(totals.get(key, 0.0))

        if previous is None:
            # First observation: import the current raw counter as the baseline total.
            total = max(total, current)
        elif current >= float(previous):
            total += current - float(previous)
        else:
            # Raw counter reset. Add the post-reset value as new traffic.
            total += current

        labels = dict(sample.labels)
        if not labels.get("friendly_name"):
            fallback = labels.get("allowed_ips", "").split(",", 1)[0].strip()
            if not fallback:
                public_key = labels.get("public_key", "")
                fallback = (public_key[:16] + "...") if len(public_key) > 16 else public_key
            labels["friendly_name"] = fallback or key

        last_raw[key] = current
        totals[key] = total
        labels_store[key] = labels
        metrics_store[key] = sample.persistent_metric

    state["updated_at"] = int(now if now is not None else time.time())


def render_metrics(state: Mapping[str, object], scrape_success: bool, scrape_error: str = "") -> str:
    totals: Mapping[str, float] = state.get("totals", {}) if isinstance(state.get("totals"), dict) else {}
    labels_store: Mapping[str, Mapping[str, str]] = state.get("labels", {}) if isinstance(state.get("labels"), dict) else {}
    metrics_store: Mapping[str, str] = state.get("metrics", {}) if isinstance(state.get("metrics"), dict) else {}
    updated_at = int(state.get("updated_at", 0) or 0)

    lines: List[str] = []
    for metric in ["awg_persistent_received_bytes_total", "awg_persistent_sent_bytes_total"]:
        lines.append(f"# HELP {metric} {HELP_TEXT[metric]}")
        lines.append(f"# TYPE {metric} counter")
        for key in sorted(totals):
            if metrics_store.get(key) != metric:
                continue
            labels = labels_store.get(key, {})
            label_text = format_labels(labels)
            value = float(totals[key])
            lines.append(f"{metric}{{{label_text}}} {value:.0f}")

    lines.append("# HELP awg_persistent_traffic_scrape_success Whether the last raw exporter scrape succeeded: 1 success, 0 failure.")
    lines.append("# TYPE awg_persistent_traffic_scrape_success gauge")
    lines.append(f"awg_persistent_traffic_scrape_success {1 if scrape_success else 0}")
    lines.append("# HELP awg_persistent_traffic_state_last_update_seconds Unix timestamp of the last state update attempt.")
    lines.append("# TYPE awg_persistent_traffic_state_last_update_seconds gauge")
    lines.append(f"awg_persistent_traffic_state_last_update_seconds {updated_at}")
    if scrape_error:
        err = escape_label_value(scrape_error[:180])
        lines.append("# HELP awg_persistent_traffic_last_error Last scrape error, exposed as a label with value 1.")
        lines.append("# TYPE awg_persistent_traffic_last_error gauge")
        lines.append(f'awg_persistent_traffic_last_error{{error="{err}"}} 1')
    return "\n".join(lines) + "\n"


def fetch_text(url: str, timeout: float) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "awg-persistent-traffic-exporter/1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def locked_state_update(state_file: Path, source_url: str, timeout: float) -> Tuple[str, bool, str]:
    lock_path = state_file.with_suffix(state_file.suffix + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock_fh:
        if fcntl is not None:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        state = load_state(state_file)
        scrape_success = False
        scrape_error = ""
        try:
            raw_text = fetch_text(source_url, timeout)
            samples = parse_wireguard_samples(raw_text)
            update_state_with_samples(state, samples)
            scrape_success = True
        except Exception as exc:  # The exporter should still expose saved totals.
            state["updated_at"] = int(time.time())
            scrape_error = f"{type(exc).__name__}: {exc}"
        save_state(state_file, state)
        rendered = render_metrics(state, scrape_success=scrape_success, scrape_error=scrape_error)
        if fcntl is not None:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
        return rendered, scrape_success, scrape_error


class MetricsHandler(BaseHTTPRequestHandler):
    source_url: str = "http://127.0.0.1:9586/metrics"
    state_file: Path = Path("/var/lib/wgexporter/traffic_totals.json")
    timeout: float = 3.0

    def do_GET(self) -> None:  # noqa: N802 - stdlib API
        if self.path not in ("/metrics", "/"):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"not found\n")
            return
        rendered, _, _ = locked_state_update(self.state_file, self.source_url, self.timeout)
        body = rendered.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))


def run_server(listen: str, port: int, source_url: str, state_file: Path, timeout: float) -> None:
    MetricsHandler.source_url = source_url
    MetricsHandler.state_file = state_file
    MetricsHandler.timeout = timeout
    server = HTTPServer((listen, port), MetricsHandler)
    print(f"Listening on http://{listen}:{port}/metrics; source={source_url}; state={state_file}", flush=True)
    server.serve_forever()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Persistent traffic exporter for WireGuard/AmneziaWG Prometheus metrics")
    parser.add_argument("--listen", default=os.environ.get("AWG_TRAFFIC_LISTEN", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("AWG_TRAFFIC_PORT", "9587")))
    parser.add_argument("--source-url", default=os.environ.get("AWG_TRAFFIC_SOURCE_URL", "http://127.0.0.1:9586/metrics"))
    parser.add_argument("--state-file", type=Path, default=Path(os.environ.get("AWG_TRAFFIC_STATE_FILE", "/var/lib/wgexporter/traffic_totals.json")))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("AWG_TRAFFIC_TIMEOUT", "3")))
    parser.add_argument("--once", action="store_true", help="Scrape once, update state, print metrics, and exit")
    args = parser.parse_args(argv)

    if args.once:
        rendered, success, error = locked_state_update(args.state_file, args.source_url, args.timeout)
        sys.stdout.write(rendered)
        if not success:
            sys.stderr.write(error + "\n")
            return 1
        return 0

    run_server(args.listen, args.port, args.source_url, args.state_file, args.timeout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

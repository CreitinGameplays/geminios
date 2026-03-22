#!/usr/bin/env python3
import argparse
import concurrent.futures
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


REPO_ROOT = Path(__file__).resolve().parents[1]
PORTS_DIR = REPO_ROOT / "ports"
USER_AGENT = "GeminiOSSourceVerifier/1.0"
SOURCE_PREFIX = "__SOURCE__"


class Colors:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    RED = "\033[91m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    CYAN = "\033[96m"


def color(text, code):
    return f"{code}{text}{Colors.RESET}"


def discover_ports(selected_ports):
    if selected_ports:
        ports = []
        for port in selected_ports:
            build_script = PORTS_DIR / port / "build.sh"
            if not build_script.is_file():
                raise ValueError(f"Unknown port '{port}'")
            ports.append((port, build_script))
        return ports

    ports = []
    for build_script in sorted(PORTS_DIR.glob("*/build.sh")):
        ports.append((build_script.parent.name, build_script))
    return ports


def extract_source_spec(port_name, build_script):
    try:
        script_text = build_script.read_text()
    except UnicodeDecodeError:
        script_text = build_script.read_text(errors="ignore")

    if "http://" not in script_text and "https://" not in script_text:
        return {
            "port": port_name,
            "status": "skipped",
            "reason": "no URL literals found",
        }

    with tempfile.TemporaryDirectory(prefix="geminios-source-verify-") as temp_root:
        temp_root_q = shlex.quote(temp_root)
        build_script_q = shlex.quote(str(build_script))
        shell_script = f"""
set -e
export ROOT_DIR={temp_root_q}
export DEP_DIR="$ROOT_DIR/external_dependencies"
export ROOTFS="$ROOT_DIR/rootfs"
export LOG_DIR="$ROOT_DIR/logs"
export OUTPUT_DIR="$ROOT_DIR/output"
export PACKAGES_DIR="$ROOT_DIR/ports"
export JOBS=1
mkdir -p "$DEP_DIR" "$ROOTFS" "$LOG_DIR" "$OUTPUT_DIR"
download_and_extract() {{
    printf '{SOURCE_PREFIX}\\tdownload\\t%s\\t%s\\t%s\\n' "$1" "$2" "$3"
    exit 0
}}
wget() {{
    out=""
    url=""
    prev=""
    for arg in "$@"; do
        if [ "$prev" = "-O" ]; then
            out="$arg"
            prev=""
            continue
        fi
        case "$arg" in
            -O)
                prev="-O"
                ;;
            http://*|https://*)
                url="$arg"
                ;;
        esac
    done
    printf '{SOURCE_PREFIX}\\twget\\t%s\\t%s\\t-\\n' "$url" "$out"
    exit 0
}}
curl() {{
    url=""
    for arg in "$@"; do
        case "$arg" in
            http://*|https://*)
                url="$arg"
                ;;
        esac
    done
    printf '{SOURCE_PREFIX}\\tcurl\\t%s\\t-\\t-\\n' "$url"
    exit 0
}}
source {build_script_q}
"""
        result = subprocess.run(
            ["/usr/bin/bash", "-lc", shell_script],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
        )

    source_line = None
    for line in result.stdout.splitlines():
        if line.startswith(f"{SOURCE_PREFIX}\t"):
            source_line = line
            break

    if source_line is None:
        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        details = stderr or stdout or "no source declaration captured"
        if result.returncode == 0:
            return {
                "port": port_name,
                "status": "skipped",
                "reason": details,
            }
        return {
            "port": port_name,
            "status": "extract_error",
            "reason": details,
        }

    _, source_type, url, archive, dirname = source_line.split("\t", 4)
    return {
        "port": port_name,
        "status": "resolved",
        "source_type": source_type,
        "url": url,
        "archive": archive,
        "dirname": dirname,
        "build_script": str(build_script),
    }


def probe_url(url, timeout):
    headers = {"User-Agent": USER_AGENT}
    attempts = [
        urllib.request.Request(url, headers=headers, method="HEAD"),
        urllib.request.Request(
            url,
            headers={**headers, "Range": "bytes=0-0"},
            method="GET",
        ),
    ]

    last_error = None
    for request in attempts:
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return {
                    "ok": True,
                    "status_code": getattr(response, "status", 200),
                    "final_url": response.geturl(),
                }
        except urllib.error.HTTPError as exc:
            last_error = f"HTTP {exc.code}"
            if request.get_method() == "HEAD":
                continue
            return {
                "ok": False,
                "error": last_error,
                "final_url": exc.geturl(),
            }
        except urllib.error.URLError as exc:
            last_error = str(exc.reason)
            if request.get_method() == "HEAD":
                continue
            return {
                "ok": False,
                "error": last_error,
                "final_url": url,
            }
        except Exception as exc:  # pragma: no cover - defensive
            last_error = str(exc)
            if request.get_method() == "HEAD":
                continue
            return {
                "ok": False,
                "error": last_error,
                "final_url": url,
            }

    return {
        "ok": False,
        "error": last_error or "unknown error",
        "final_url": url,
    }


def verify_spec(spec, timeout):
    if spec["status"] != "resolved":
        return spec

    probe = probe_url(spec["url"], timeout)
    merged = dict(spec)
    merged.update(probe)
    merged["status"] = "ok" if probe["ok"] else "failed"
    return merged


def print_result(result):
    port = result["port"]
    if result["status"] == "ok":
        msg = f"[OK] {port}: {result['status_code']} {result['url']}"
        if result["final_url"] != result["url"]:
            msg += f" -> {result['final_url']}"
        print(color(msg, Colors.GREEN))
        return

    if result["status"] == "failed":
        msg = f"[FAIL] {port}: {result['error']} {result['url']}"
        print(color(msg, Colors.RED))
        return

    if result["status"] == "skipped":
        print(color(f"[SKIP] {port}: {result['reason']}", Colors.YELLOW))
        return

    print(color(f"[ERROR] {port}: {result['reason']}", Colors.RED))


def main():
    parser = argparse.ArgumentParser(
        description="Verify external source URLs declared by GeminiOS port build scripts."
    )
    parser.add_argument(
        "ports",
        nargs="*",
        help="Optional subset of ports to verify. Defaults to every port in ports/.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=15.0,
        help="Per-request timeout in seconds. Default: 15",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=8,
        help="Concurrent network checks. Default: 8",
    )
    args = parser.parse_args()

    try:
        ports = discover_ports(args.ports)
    except ValueError as exc:
        print(color(f"ERROR: {exc}", Colors.RED))
        return 1

    extraction_results = [extract_source_spec(port, build_script) for port, build_script in ports]

    resolved = [result for result in extraction_results if result["status"] == "resolved"]
    unresolved = [result for result in extraction_results if result["status"] != "resolved"]

    verified = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as executor:
        future_map = {
            executor.submit(verify_spec, result, args.timeout): result["port"]
            for result in resolved
        }
        for future in concurrent.futures.as_completed(future_map):
            verified.append(future.result())

    ordered_verified = sorted(verified, key=lambda item: item["port"])
    ordered_unresolved = sorted(unresolved, key=lambda item: item["port"])
    all_results = ordered_verified + ordered_unresolved

    for result in all_results:
        print_result(result)

    ok_count = sum(1 for result in all_results if result["status"] == "ok")
    fail_count = sum(1 for result in all_results if result["status"] == "failed")
    skip_count = sum(1 for result in all_results if result["status"] == "skipped")
    error_count = sum(1 for result in all_results if result["status"] == "extract_error")

    print()
    print(color("Source URL verification summary", Colors.BOLD + Colors.CYAN))
    print(f"  total ports: {len(all_results)}")
    print(f"  verified ok: {ok_count}")
    print(f"  verification failures: {fail_count}")
    print(f"  skipped: {skip_count}")
    print(f"  extraction errors: {error_count}")

    return 0 if fail_count == 0 and error_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

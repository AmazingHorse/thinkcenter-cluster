#!/usr/bin/env python3
"""boot_http_server.py — Lightweight HTTP server for PXE assets and Proxmox answer files.

Zero external dependencies (Python 3 standard library only).
Serves static assets (kernel, initrd, CPIO, autoexec.ipxe) via GET/HEAD with Range support.
Handles Proxmox VE automated installer POST requests to /assets/answers/ by inspecting
JSON MAC addresses and returning the matching per-node TOML answer file.
"""

import argparse
import json
import logging
import os
from pathlib import Path
from http.server import HTTPServer, SimpleHTTPRequestHandler
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("boot_http_server")


class BootHTTPRequestHandler(SimpleHTTPRequestHandler):
    server_root: Path = Path("/var/lib/boot")

    def __init__(self, *args, directory=None, **kwargs):
        if directory is None:
            directory = str(self.server_root)
        super().__init__(*args, directory=directory, **kwargs)

    def log_message(self, format, *args):
        logger.info("%s - %s", self.address_string(), format % args)

    def end_headers(self):
        # Enable CORS for installer environments if needed
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def guess_type(self, path):
        path_str = str(path)
        if path_str.endswith(".toml"):
            return "application/toml"
        if path_str.endswith(".ipxe"):
            return "text/plain; charset=utf-8"
        if path_str.endswith(".cpio"):
            return "application/octet-stream"
        return super().guess_type(path)

    def translate_path(self, path):
        clean_path = path.split("?", 1)[0].split("#", 1)[0]
        # Map root /autoexec.ipxe to assets/autoexec.ipxe if not at root
        if clean_path == "/autoexec.ipxe":
            root_ipxe = self.server_root / "autoexec.ipxe"
            if root_ipxe.is_file():
                return str(root_ipxe)
            assets_ipxe = self.server_root / "assets" / "autoexec.ipxe"
            if assets_ipxe.is_file():
                return str(assets_ipxe)
            alt_ipxe = self.server_root / "ipxe" / "autoexec.ipxe"
            if alt_ipxe.is_file():
                return str(alt_ipxe)

        return super().translate_path(path)

    def _resolve_answer_by_macs(self, mac_candidates):
        answers_dir = self.server_root / "assets" / "answers"
        if not answers_dir.is_dir():
            logger.warning("Answers directory not found: %s", answers_dir)
            return None

        for raw_mac in mac_candidates:
            if not isinstance(raw_mac, str):
                continue
            mac_clean = raw_mac.strip().lower()
            hyphen_name = mac_clean.replace(":", "-") + ".toml"
            colon_name = mac_clean.replace("-", ":") + ".toml"

            target_file = answers_dir / hyphen_name
            if target_file.is_file():
                logger.info("Matched answer file %s for MAC %s", target_file.name, raw_mac)
                return target_file

            target_file = answers_dir / colon_name
            if target_file.is_file():
                logger.info("Matched answer file %s for MAC %s", target_file.name, raw_mac)
                return target_file

        default_file = answers_dir / "default.toml"
        if default_file.is_file():
            logger.info("Using fallback default.toml for MACs: %s", mac_candidates)
            return default_file

        return None

    def _send_toml_file(self, file_path: Path):
        try:
            content = file_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/toml")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except OSError as e:
            logger.error("Failed to read answer file %s: %s", file_path, e)
            self.send_error(500, f"Error reading answer file: {e}")

    def do_POST(self):
        clean_path = self.path.split("?", 1)[0].rstrip("/")

        # Direct POST to a specific .toml file
        if clean_path.endswith(".toml"):
            translated = Path(self.translate_path(self.path))
            if translated.is_file():
                self._send_toml_file(translated)
                return
            self.send_error(404, f"File not found: {self.path}")
            return

        # Proxmox fetch-answer endpoint: /assets/answers or /answer
        if clean_path in ("/assets/answers", "/answer"):
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length) if content_length > 0 else b""
            mac_candidates = []

            if body:
                try:
                    payload = json.loads(body.decode("utf-8", errors="replace"))
                    if isinstance(payload, dict):
                        # PVE 9.x: "mac_addresses": ["xx:xx:xx:..."]
                        if "mac_addresses" in payload and isinstance(payload["mac_addresses"], list):
                            mac_candidates.extend(payload["mac_addresses"])
                        # PVE 8.x: "network_interfaces": [{"mac": "xx:xx:..."}, ...]
                        if "network_interfaces" in payload and isinstance(payload["network_interfaces"], list):
                            for iface in payload["network_interfaces"]:
                                if isinstance(iface, dict) and "mac" in iface:
                                    mac_candidates.append(iface["mac"])
                                elif isinstance(iface, str):
                                    mac_candidates.append(iface)
                except Exception as ex:
                    logger.warning("Failed to parse POST body JSON: %s (body: %s)", ex, body[:100])

            matched_file = self._resolve_answer_by_macs(mac_candidates)
            if matched_file:
                self._send_toml_file(matched_file)
                return

            msg = f"No answer file matched received MACs: {mac_candidates}"
            logger.error(msg)
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(msg.encode("utf-8"))
            return

        self.send_error(404, f"Unsupported POST path: {self.path}")


def main():
    parser = argparse.ArgumentParser(description="PXE Asset & Answer HTTP Server")
    parser.add_argument("--root", default="/var/lib/boot", help="Root directory for boot assets")
    parser.add_argument("--port", type=int, default=8080, help="Listen port (default: 8080)")
    parser.add_argument("--bind", default="0.0.0.0", help="Bind IP address (default: 0.0.0.0)")
    args = parser.parse_args()

    root_path = Path(args.root).resolve()
    if not root_path.exists():
        logger.warning("Root directory %s does not exist; creating.", root_path)
        root_path.mkdir(parents=True, exist_ok=True)

    BootHTTPRequestHandler.server_root = root_path

    server = HTTPServer((args.bind, args.port), BootHTTPRequestHandler)
    logger.info("Serving boot assets from %s on %s:%d", root_path, args.bind, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down server.")
        server.server_close()


if __name__ == "__main__":
    main()

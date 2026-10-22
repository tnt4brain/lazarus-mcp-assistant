#!/usr/bin/env python3
"""Stdio -> HTTP bridge for the Lazarus MCP Assistant.

Some MCP clients do not start a new session when the IDE's HTTP server
forgets the old one (after `ide_rebuild`, or after closing and reopening
the IDE): they keep replaying the dead session id and every call fails
with -32001 "Session not found" until the conversation is restarted.
Claude Code re-initializes by itself; ZCode, for one, does not.

This bridge is spawned by such a client as an ordinary stdio MCP server.
It forwards every message to the plugin's HTTP endpoint and, whenever the
server reports the old session gone (or is not running yet), starts a
fresh HTTP session - and, by default, the IDE itself. IDE restarts become
transparent to the conversation.

The server address and bearer token are read from `mcpassistantoptions.xml`
in the IDE's primary config directory, so the bridge follows the IDE's
persisted port and token with no per-client setup.

Environment variables:
  LAZARUS_MCP_PCP        the IDE's primary config directory when it does
                         not live in a standard place (it is looked up in
                         %LOCALAPPDATA%\\lazarus, ~/.lazarus and
                         ~/.config/lazarus otherwise)
  LAZARUS_MCP_IDE_EXE    IDE executable for auto-start
                         (default: <config parent>/lazarus/lazarus.exe,
                         i.e. fpcupdeluxe-style installs)
  LAZARUS_MCP_AUTOSTART  set to 0 to disable IDE auto-start
  LAZARUS_MCP_URL / LAZARUS_MCP_TOKEN  full endpoint override
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

HTTP_TIMEOUT = 600          # seconds; long debugger calls must survive
BOOT_TIMEOUT = 150          # seconds to wait for a starting IDE
STALE_CODES = (-32001,)     # "Session not found; send initialize"
AUTOSTART = os.environ.get("LAZARUS_MCP_AUTOSTART", "1") != "0"

def log(msg):
    sys.stderr.write("[mcp-stdio-bridge] %s\n" % msg)
    sys.stderr.flush()

def find_options_file():
    override = os.environ.get("LAZARUS_MCP_PCP")
    if override:
        return os.path.join(override, "mcpassistantoptions.xml")
    candidates = [os.path.join(os.environ.get("LOCALAPPDATA", ""), "lazarus"),
                  os.path.expanduser("~/.lazarus"),
                  os.path.expanduser("~/.config/lazarus")]
    for directory in candidates:
        path = os.path.join(directory, "mcpassistantoptions.xml")
        if os.path.exists(path):
            return path
    raise SystemExit("mcpassistantoptions.xml not found; "
                     "set LAZARUS_MCP_PCP to the IDE's primary config directory")

def read_endpoint():
    url = os.environ.get("LAZARUS_MCP_URL")
    token = os.environ.get("LAZARUS_MCP_TOKEN")
    if url and token:
        return url, token
    srv = ET.parse(find_options_file()).getroot().find("Server")
    addr = (srv.get("ListenAddress") or "127.0.0.1").strip()
    return "http://%s:%s/mcp" % (addr, srv.get("Port")), srv.get("Token")

def pcp_dir():
    override = os.environ.get("LAZARUS_MCP_PCP")
    if override:
        return override
    return os.path.dirname(find_options_file())

def ide_exe():
    exe = os.environ.get("LAZARUS_MCP_IDE_EXE")
    if exe:
        return exe if os.path.exists(exe) else None
    root = os.path.dirname(os.path.abspath(pcp_dir()))
    for name in ("lazarus.exe", "startlazarus.exe", "startlazarus", "lazarus"):
        cand = os.path.join(root, "lazarus", name)
        if os.path.exists(cand):
            return cand
    return None

URL, TOKEN = read_endpoint()
_parts = urlsplit(URL)
HOST, PORT = _parts.hostname, _parts.port or 80

def port_open():
    try:
        with socket.create_connection((HOST, PORT), timeout=1):
            return True
    except OSError:
        return False

SYNTH_INIT = {
    "jsonrpc": "2.0", "id": "bridge-init", "method": "initialize",
    "params": {"protocolVersion": "2025-03-26", "capabilities": {},
               "clientInfo": {"name": "mcp-stdio-bridge", "version": "1.0"}},
}
INITIALIZED_NOTE = {"jsonrpc": "2.0", "method": "notifications/initialized"}


class Bridge:
    def __init__(self):
        self.lock = threading.Lock()
        self.session = None
        self.boot_lock = threading.Lock()

    def start_ide_and_wait(self):
        with self.boot_lock:
            if port_open():
                return
            exe = ide_exe()
            if not exe:
                log("IDE auto-start requested but no IDE executable found; "
                    "set LAZARUS_MCP_IDE_EXE")
                return
            log("server unreachable, starting IDE: %s" % exe)
            try:
                subprocess.Popen([exe, "--pcp=" + pcp_dir()],
                                 cwd=os.path.dirname(exe))
            except OSError as e:
                log("IDE auto-start failed: %s" % e)
                return
            deadline = time.time() + BOOT_TIMEOUT
            while time.time() < deadline:
                if port_open():
                    log("IDE is up after %ds"
                        % int(BOOT_TIMEOUT - (deadline - time.time())))
                    return
                time.sleep(2)
            log("IDE did not come up within %ds" % BOOT_TIMEOUT)

    def post(self, payload, with_session):
        headers = {
            "Authorization": "Bearer " + (TOKEN or ""),
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if with_session and self.session:
            headers["Mcp-Session-Id"] = self.session
            headers["Cookie"] = "mcp_session=" + self.session
        req = urllib.request.Request(
            URL, data=json.dumps(payload).encode("utf-8"),
            headers=headers, method="POST")
        try:
            resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT)
        except urllib.error.HTTPError as e:
            resp = e  # error responses still carry a JSON-RPC body
        with resp:
            status = resp.getcode()
            ctype = resp.headers.get("Content-Type", "") or ""
            sid = resp.headers.get("Mcp-Session-Id")
            raw = resp.read().decode("utf-8", "replace").strip()
        return status, ctype, raw, sid

    @staticmethod
    def parse_body(ctype, raw):
        if not raw:
            return None
        if "text/event-stream" in ctype:
            events = [line[5:].strip() for line in raw.splitlines()
                      if line.startswith("data:")]
            if not events:
                return None
            raw = events[-1]
        try:
            return json.loads(raw)
        except ValueError:
            return None

    def initialize_session(self):
        self.session = None
        status, ctype, raw, sid = self.post(SYNTH_INIT, with_session=False)
        if sid:
            self.session = sid
        self.post(INITIALIZED_NOTE, with_session=True)
        if self.session:
            log("HTTP session initialized (%s)" % self.session)
        else:
            log("initialize returned no session id (status %s): %s"
                % (status, raw[:200]))

    @staticmethod
    def is_stale(status, resp):
        if status == 404:
            return True
        return isinstance(resp, dict) and resp.get("error", {}).get(
            "code") in STALE_CODES

    def call_upstream(self, msg):
        last_err = None
        for attempt in (1, 2, 3):
            try:
                status, ctype, raw, sid = self.post(msg, with_session=True)
            except (urllib.error.URLError, OSError) as e:
                last_err = "server unreachable: %s" % e
                if attempt == 1 and AUTOSTART:
                    self.start_ide_and_wait()
                    continue
                break
            if sid:
                with self.lock:
                    self.session = sid
            resp = self.parse_body(ctype, raw)
            if self.is_stale(status, resp) or (msg.get("id") is not None
                                               and resp is None
                                               and status >= 400):
                log("stale session (status %s), re-initializing" % status)
                with self.lock:
                    self.session = None
                self.initialize_session()
                continue
            return resp
        raise RuntimeError(last_err or "upstream call failed after retries")

    def handle(self, msg):
        is_request = msg.get("id") is not None
        try:
            resp = self.call_upstream(msg)
        except Exception as e:
            log("call failed: %s" % e)
            if is_request:
                emit({"jsonrpc": "2.0", "id": msg["id"],
                      "error": {"code": -32603,
                                "message": "mcp-stdio-bridge: %s" % e}})
            return
        if is_request:
            if resp is None:
                emit({"jsonrpc": "2.0", "id": msg["id"],
                      "error": {"code": -32603,
                                "message": "mcp-stdio-bridge: empty response"}})
            else:
                emit(resp)


out_lock = threading.Lock()
pending = []

def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()

def main():
    bridge = Bridge()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if not isinstance(msg, dict):
            continue
        t = threading.Thread(target=bridge.handle, args=(msg,), daemon=True)
        t.start()
        pending.append(t)
    for t in pending:
        t.join(timeout=HTTP_TIMEOUT + 10)

if __name__ == "__main__":
    log("bridging stdio <-> %s (autostart=%s)" % (URL, AUTOSTART))
    main()

#!/usr/bin/env python3
"""Exercise the real stdio bridge against a local, credential-free MCP fixture.
Run after `swift build --product harnais`; never reads live Harnais accounts.
"""
import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import uuid

lock = threading.Lock()
state = {"refreshes": 0, "sessions": {}, "errors": [], "replies": {}, "redirect_hits": 0}


class Server(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def respond(self, code, obj=None, headers=None):
        body = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_GET(self):
        self.respond(405)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/token":
            # Keep both providers waiting, as a real rotating-token server would.
            time.sleep(0.15)
            with lock:
                state["refreshes"] += 1
                number = state["refreshes"]
            self.respond(200, {"access_token": f"access-{number}", "refresh_token": f"refresh-{number}", "expires_in": 3600, "token_type": "Bearer"})
            return
        if self.path == "/leak":
            state["redirect_hits"] += 1
            self.respond(500)
            return
        if self.path == "/redirect":
            self.respond(307, headers={"Location": endpoint + "/leak"})
            return
        message = json.loads(body)
        method = message.get("method")
        if self.path == "/public":
            assert self.headers.get("Authorization") is None, "public MCP received an authorization header"
            if method == "initialize":
                self.respond(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": "2025-11-25", "capabilities": {}, "serverInfo": {"name": "public-fixture", "version": "1"}}})
            else: self.respond(202)
            return
        if self.headers.get("Authorization") != f'Bearer access-{state["refreshes"]}':
            self.respond(401)
            return
        if method == "initialize":
            session = str(uuid.uuid4())
            state["sessions"][session] = True
            state["replies"][session] = threading.Event()
            self.respond(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": "2025-11-25", "capabilities": {}, "serverInfo": {"name": "fixture", "version": "1"}}}, {"MCP-Session-Id": session})
            return
        session = self.headers.get("MCP-Session-Id")
        if session not in state["sessions"] or self.headers.get("MCP-Protocol-Version") != "2025-11-25":
            state["errors"].append("missing session or negotiated protocol header")
            self.respond(400)
            return
        if "result" in message:
            state["replies"][session].set()
            self.respond(202)
        elif method == "notifications/initialized":
            self.respond(202)
        elif method == "tools/call":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            # A buffered or sequential proxy deadlocks here: the result depends
            # on receiving the client's answer to this server-initiated request.
            request = {"jsonrpc": "2.0", "id": "server-question", "method": "elicitation/create", "params": {"message": "Fixture", "requestedSchema": {"type": "object"}}}
            self.wfile.write(b"data: " + json.dumps(request).encode() + b"\n\n")
            self.wfile.flush()
            if not state["replies"][session].wait(8):
                state["errors"].append("streaming request deadlocked")
                return
            result = {"jsonrpc": "2.0", "id": message["id"], "result": {"content": [{"type": "text", "text": "shared works"}]}}
            self.wfile.write(b"data: " + json.dumps(result).encode() + b"\r\n\r\n")
            self.wfile.flush()
            self.close_connection = True
        else:
            self.respond(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"tools": []}})


def receive(process):
    output = queue.Queue()
    threading.Thread(target=lambda: output.put(process.stdout.readline()), daemon=True).start()
    line = output.get(timeout=10)
    assert line, "bridge exited before replying"
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        raise AssertionError(f"Invalid stdio JSON line: {line!r}")


def send(process, obj):
    process.stdin.write(json.dumps(obj).encode() + b"\n")
    process.stdin.flush()


def initialize(process):
    send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "fixture", "version": "1"}}})
    assert receive(process)["result"]["protocolVersion"] == "2025-11-25"
    send(process, {"jsonrpc": "2.0", "method": "notifications/initialized"})


httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
endpoint = f"http://127.0.0.1:{httpd.server_port}"
threading.Thread(target=httpd.serve_forever, daemon=True).start()
processes = []
try:
    with tempfile.TemporaryDirectory(prefix="harnais-shared-test-") as temporary:
        home = Path(temporary)
        connection = {"id": str(uuid.uuid4()), "kind": "custom-mcp", "label": "Fixture", "slug": "fixture", "mcpName": "fixture", "createdAt": "2026-01-01T00:00:00Z", "endpointURL": endpoint + "/mcp"}
        (home / "integrations.json").write_text(json.dumps({"schemaVersion": 1, "connections": [connection]}))
        credential = home / "integrations/custom-mcp/fixture/credentials.json"
        credential.parent.mkdir(parents=True)
        credential.write_text(json.dumps({"oauth": {"clientId": "fixture", "accessToken": "expired", "refreshToken": "refresh-original", "expiresAt": "2020-01-01T00:00:00Z", "tokenType": "Bearer", "resource": endpoint + "/mcp", "tokenEndpoint": endpoint + "/token"}}))
        binary = str(Path(os.environ.get("HARNAIS_TEST_BINARY", ".build/debug/harnais")).resolve())
        for _ in range(2):
            processes.append(subprocess.Popen([binary, "mcp", "serve", "fixture"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, "HARNAIS_DATA_DIR": temporary}))
        with concurrent.futures.ThreadPoolExecutor() as pool:
            list(pool.map(initialize, processes))
        assert state["refreshes"] == 1, "concurrent providers refreshed the same rotating token twice"
        assert len(state["sessions"]) == 2, "providers must use separate MCP sessions"
        for process in processes:
            send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "fixture"}})
            question = receive(process)
            assert question["id"] == "server-question"
            send(process, {"jsonrpc": "2.0", "id": question["id"], "result": {"action": "accept", "content": {}}})
            assert receive(process)["result"]["content"][0]["text"] == "shared works"
        # Both clients now reject the same cached token: only one may rotate it.
        saved = json.loads(credential.read_text())
        saved["oauth"]["accessToken"] = "rejected"
        credential.write_text(json.dumps(saved))
        for process in processes:
            send(process, {"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
        for process in processes:
            assert receive(process)["result"] == {"tools": []}
        assert state["refreshes"] == 2, "401 retry should rotate once across accounts"
        assert not state["errors"], state["errors"]
        # Redirecting servers must never receive the bearer token elsewhere.
        connection["endpointURL"] = endpoint + "/redirect"
        (home / "integrations.json").write_text(json.dumps({"schemaVersion": 1, "connections": [connection]}))
        saved = json.loads(credential.read_text())
        saved["oauth"]["resource"] = connection["endpointURL"]
        credential.write_text(json.dumps(saved))
        process = subprocess.Popen([binary, "mcp", "serve", "fixture"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, "HARNAIS_DATA_DIR": temporary})
        processes.append(process)
        send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        assert "307" in receive(process)["error"]["message"]
        assert state["redirect_hits"] == 0, "bearer credential followed redirect"
        # Refresh requests contain credentials too and must not follow redirects.
        saved["oauth"]["tokenEndpoint"] = endpoint + "/redirect"
        saved["oauth"]["expiresAt"] = "2020-01-01T00:00:00Z"
        credential.write_text(json.dumps(saved))
        send(process, {"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {}})
        assert "Shared login is unavailable" in receive(process)["error"]["message"]
        assert state["redirect_hits"] == 0, "OAuth credential followed redirect"
        connection.update(kind="excalidraw", endpointURL=endpoint + "/public")
        (home / "integrations.json").write_text(json.dumps({"schemaVersion": 1, "connections": [connection]}))
        process = subprocess.Popen([binary, "mcp", "serve", "fixture"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, "HARNAIS_DATA_DIR": temporary})
        processes.append(process)
        initialize(process)
        print("Shared MCP e2e passed: public unauthenticated server, concurrent refresh, isolated sessions, interactive SSE, 401 recovery, MCP and OAuth redirect refusal")
finally:
    for process in processes:
        process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
    httpd.shutdown()

#!/usr/bin/env python3
"""Read-only live MCP checks for each registered account's actual configuration.
Does not modify configuration or print credentials or returned service data.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import tomllib


class MCP:
    def __init__(self, command, args, env):
        self.process = subprocess.Popen([command, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env={**os.environ, **env})
        self.replies = queue.Queue()
        def read():
            try:
                while line := self.process.stdout.readline():
                    if line.lower().startswith(b'content-length:'):
                        length = int(line.split(b':', 1)[1])
                        while self.process.stdout.readline().strip():
                            pass
                        line = self.process.stdout.read(length)
                    self.replies.put(json.loads(line))
            except Exception:
                pass
            self.replies.put(None)
        threading.Thread(target=read, daemon=True).start()
        self.next_id = 0

    def send(self, message):
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', **message}).encode() + b'\n')
        self.process.stdin.flush()

    def request(self, method, params=None):
        self.next_id += 1
        self.send({'id': self.next_id, 'method': method, 'params': params or {}})
        for _ in range(100):
            reply = self.replies.get(timeout=35)
            if reply is None:
                raise RuntimeError('Server exited before replying')
            if reply.get('id') == self.next_id:
                if 'error' in reply:
                    # Never print upstream text, which may contain credentials or user data.
                    raise RuntimeError('MCP error code ' + str(reply['error'].get('code')))
                return reply['result']
            if 'id' in reply and 'method' in reply:
                self.send({'id': reply['id'], 'error': {'code': -32601, 'message': 'Read-only probe'}})
        raise RuntimeError('Too many notifications')

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def probe(command, args, env, tool=None):
    client = MCP(command, args, env)
    try:
        init = client.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                                            'clientInfo': {'name': 'harnais-migration-check', 'version': '1'}})
        client.send({'method': 'notifications/initialized'})
        tools = []
        cursor = None
        for _ in range(30):
            result = client.request('tools/list', {'cursor': cursor} if cursor else {})
            tools.extend(result.get('tools', []))
            cursor = result.get('nextCursor')
            if not cursor:
                break
        if cursor:
            raise RuntimeError('Incomplete tool inventory')
        fingerprint = hashlib.sha256(json.dumps(sorted(tools, key=lambda t: t['name']), sort_keys=True).encode()).hexdigest()
        report = {'status': 'passed', 'protocol': init.get('protocolVersion'), 'tools': len(tools),
                  'toolNames': sorted(t['name'] for t in tools), 'schemaHash': fingerprint}
        if tool:
            report['queryTool'] = tool
            started = time.monotonic()
            if tool not in report['toolNames']:
                raise RuntimeError('Read-only test tool unavailable')
            result = client.request('tools/call', {'name': tool, 'arguments': {'pageSize': 1, 'excludeContentSnippets': True} if tool == 'list_recent_files' else {'limit': 1} if tool in ('outlook_list_messages', 'gmail_list_messages', 'whatsapp_list_chats', 'whatsapp_list_documents') else {'pageSize': 1} if tool == 'list_messages' else {'query': 'wave'} if tool == 'slack_search_emojis' else {}})
            report['queryDurationMS'] = round((time.monotonic() - started) * 1000)
            report['readCall'] = 'failed' if result.get('isError') else 'passed'
            if result.get('isError'):
                report['status'] = 'failed'
        return report
    finally:
        client.close()


def config(account):
    home = Path(account.get('shadowHomePath') or account['homePath'])
    env = account.get('env', {})
    provider = account['provider']
    if provider == 'claude':
        path = Path.home() / '.claude.json' if account.get('importedDefault') and not env.get('CLAUDE_CONFIG_DIR') else Path(env.get('CLAUDE_CONFIG_DIR', home)) / '.claude.json'
    elif provider == 'codex':
        path = Path(env.get('CODEX_HOME', home)) / 'config.toml'
    elif provider == 'cursor':
        path = Path(env.get('CURSOR_CONFIG_DIR', home)) / 'mcp.json'
    else:
        base = Path(env.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'opencode'
        path = Path(env.get('OPENCODE_CONFIG', base / ('opencode.jsonc' if (base / 'opencode.jsonc').exists() else 'opencode.json')))
    raw = path.read_text()
    if path.suffix == '.toml':
        root = tomllib.loads(raw)
    else:
        # Exporter writes standard JSON; fail explicitly on unsupported JSONC.
        root = json.loads(raw)
    servers = root.get('mcp_servers', root.get('mcpServers', root.get('mcp', {})))
    return servers.get('servers', servers)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('--tool', choices=['list_datasources', 'list_recent_files', 'outlook_list_messages', 'list_messages', 'list_labels', 'getAccessibleAtlassianResources', 'gmail_list_labels', 'gmail_list_messages', 'read_me', 'read_diagram_guide', 'describe_scene', 'aikido_issues_list', 'slack_search_emojis', 'whatsapp_list_chats', 'whatsapp_list_documents', 'whatsapp_status'])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--record', action='store_true', help='Save dated results for display in Harnais')
    args = parser.parse_args()
    accounts = json.loads((Path.home() / '.harnais/accounts.json').read_text())['accounts']
    registry = json.loads((Path.home() / '.harnais/integrations.json').read_text())
    connection = next((c for c in registry['connections'] if c['mcpName'] == args.name), {})
    reports = []
    for account in accounts:
        report = {'accountID': account['id'], 'provider': account['provider'], 'account': account['label'], 'connection': args.name}
        try:
            if connection.get('isExcludedFromApply') or account['id'] in connection.get('excludedAccountIDs', []):
                report.update(status='paused', reason='Disabled in Harnais for this account')
                reports.append(report)
                print(json.dumps(report), flush=True)
                continue
            server = config(account).get(args.name)
            if not server:
                report['status'] = 'missing'
            elif server.get('enabled') is False or server.get('disabled') is True:
                report.update(status='disabled', reason='Disabled in account configuration')
            else:
                cmd = server['command']
                command, arguments = (cmd[0], cmd[1:]) if isinstance(cmd, list) else (cmd, server.get('args', []))
                env = {**account.get('env', {}), **server.get('env', {}), **server.get('environment', {})}
                if account['provider'] == 'claude': env.setdefault('CLAUDE_CONFIG_DIR', account['homePath'])
                if account['provider'] == 'cursor': env.setdefault('CURSOR_CONFIG_DIR', account['homePath'])
                if account['provider'] == 'codex': env.setdefault('CODEX_HOME', account.get('shadowHomePath') or account['homePath'])
                report.update(probe(command, arguments, env, args.tool))
        except Exception as error:
            report.update(status='failed', reason=type(error).__name__)
        reports.append(report)
        print(json.dumps({k: v for k, v in report.items() if k not in ('toolNames', 'schemaHash')}), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as handle:
            json.dump(reports, handle, indent=2)
    if args.record:
        registry = json.loads((Path.home() / '.harnais/integrations.json').read_text())
        connection = next(c for c in registry['connections'] if c['mcpName'] == args.name)
        directory = Path.home() / '.harnais/connection-checks'
        directory.mkdir(mode=0o700, exist_ok=True)
        destination = directory / (connection['id'] + '.json')
        temporary = destination.with_suffix('.tmp')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as handle:
            json.dump({'checkedAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'results': reports}, handle, indent=2)
        os.replace(temporary, destination)
    return 0 if all(r['status'] in ('passed', 'paused') for r in reports) else 1


if __name__ == '__main__':
    raise SystemExit(main())

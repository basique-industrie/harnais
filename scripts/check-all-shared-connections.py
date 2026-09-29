#!/usr/bin/env python3
"""Run one read-only MCP query per shared connection through every registered account.
Reads each account's actual configuration; it does not ask a model to choose a tool.
Stores only status, tool metadata and duration, never returned service content.
"""
import argparse
import concurrent.futures
import datetime
import json
from pathlib import Path
import subprocess
import sys

QUERIES = {
    'google-drive': 'list_recent_files', 'gmail': 'gmail_list_messages',
    'outlook': 'outlook_list_messages', 'grafana': 'list_datasources',
    'atlassian': 'getAccessibleAtlassianResources', 'slack': 'slack_search_emojis',
    'aikido': 'aikido_issues_list', 'whatsapp': 'whatsapp_list_chats',
}


def query_for(connection):
    if connection['kind'] == 'excalidraw':
        return 'describe_scene' if connection.get('localCanvas') else 'read_me'
    return QUERIES.get(connection['kind'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
    connections = json.loads((Path.home() / '.harnais/integrations.json').read_text())['connections']
    script = Path(__file__).with_name('probe-shared-connections.py')

    def run(connection):
        name, tool = connection['mcpName'], query_for(connection)
        if connection.get('isExcludedFromApply'):
            return {'connection': name, 'status': 'paused', 'passed': 0, 'total': 0}
        if not tool:
            return {'connection': name, 'status': 'unsupported', 'passed': 0, 'total': 0}
        destination = args.output / (name + '.json')
        command = [sys.executable, str(script), name, '--tool', tool, '--output', str(destination)]
        if args.record:
            command.append('--record')
        completed = subprocess.run(command, capture_output=True, text=True)
        rows = json.loads(destination.read_text()) if destination.exists() else []
        passed = sum(r.get('status') == 'passed' and r.get('readCall') == 'passed' for r in rows)
        return {'connection': name, 'query': tool, 'status': 'passed' if completed.returncode == 0 and rows else 'failed',
                'passed': passed, 'total': sum(r.get('status') != 'paused' for r in rows)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(run, connection) for connection in connections]
        results = []
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            print(json.dumps(result), flush=True)
    report = {'checkedAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
              'scope': 'Direct MCP queries through saved account configurations; no model invocation',
              'results': sorted(results, key=lambda r: r['connection'])}
    destination = args.output / 'summary.json'
    destination.write_text(json.dumps(report, indent=2) + '\n')
    destination.chmod(0o600)
    return 0 if results and all(r['status'] == 'passed' for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())

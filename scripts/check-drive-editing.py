#!/usr/bin/env python3
"""Exercise Drive editing using newly created private fixtures, then trash those fixtures.
Never edits existing documents. Records tool names, fixture IDs and assertions, not credentials.
"""
import argparse
import base64
import importlib.util
import io
import json
from pathlib import Path
import uuid
import zipfile


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


probe = module('probe', 'probe-shared-connections.py')
reader = module('reader', 'check-drive-reader.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--name', default='harnais-google-drive-personal')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all-accounts', action='store_true')
    args = parser.parse_args()
    client = probe.MCP(args.binary, ['mcp', 'serve', args.name], {})
    created, cleaned, checks = [], [], []
    local_folders = []

    def init(mcp):
        mcp.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'harnais-editor-check', 'version': '1'}})
        mcp.send({'method': 'notifications/initialized'})

    def call(tool, arguments, mcp=client):
        response = mcp.request('tools/call', {'name': tool, 'arguments': arguments})
        if response.get('isError'):
            raise RuntimeError(tool + ': ' + response['content'][0]['text'])
        return json.loads(response['content'][0]['text'])

    def check(label):
        checks.append({'check': label, 'status': 'passed'})
        print(json.dumps(checks[-1]), flush=True)

    def create(tool, arguments):
        value = call(tool, arguments)
        created.append(value['id'])
        return value

    error = None
    try:
        init(client)
        names = {t['name'] for t in client.request('tools/list')['tools']}
        assert len(names) == 29 and 'replace_file_content' in names
        check('29 unique tools exposed')
        folder = create('create_file', {'title': 'Harnais editing test ' + str(uuid.uuid4()), 'mimeType': 'application/vnd.google-apps.folder'})['id']
        sheet = create('create_spreadsheet', {'title': 'Workbook fixture', 'parentId': folder})['id']
        call('batch_update_spreadsheet', {'fileId': sheet, 'requests': [
            {'addSheet': {'properties': {'sheetId': 100, 'title': 'Data'}}},
            {'updateSheetProperties': {'properties': {'sheetId': 100, 'gridProperties': {'frozenRowCount': 1}}, 'fields': 'gridProperties.frozenRowCount'}},
            {'repeatCell': {'range': {'sheetId': 100, 'startRowIndex': 0, 'endRowIndex': 1}, 'cell': {'userEnteredFormat': {'textFormat': {'bold': True}}}, 'fields': 'userEnteredFormat.textFormat.bold'}}
        ]})
        call('update_spreadsheet_values', {'fileId': sheet, 'valueInputOption': 'USER_ENTERED', 'data': [{'range': 'Data!A1:C2', 'values': [['Amount', 'Double', 'Literal'], [21, '=A2*2', 'value']]}]})
        values = call('read_spreadsheet_values', {'fileId': sheet, 'ranges': ['Data!A2:B2'], 'valueRenderOption': 'UNFORMATTED_VALUE'})
        assert values['valueRanges'][0]['values'] == [[21, 42]]
        formulas = call('read_spreadsheet_values', {'fileId': sheet, 'ranges': ['Data!B2'], 'valueRenderOption': 'FORMULA'})
        assert formulas['valueRanges'][0]['values'] == [['=A2*2']]
        call('update_spreadsheet_values', {'fileId': sheet, 'data': [{'range': 'Data!C2', 'values': [['=literal-not-a-formula']]}]})
        meta = call('get_spreadsheet', {'fileId': sheet, 'ranges': ['Data!A1:C2'], 'includeGridData': True})
        data_sheet = next(s for s in meta['sheets'] if s['properties']['sheetId'] == 100)
        assert data_sheet['properties']['gridProperties']['frozenRowCount'] == 1
        assert data_sheet['data'][0]['rowData'][0]['values'][0]['userEnteredFormat']['textFormat']['bold'] is True
        assert data_sheet['data'][0]['rowData'][1]['values'][2]['userEnteredValue']['stringValue'] == '=literal-not-a-formula'
        check('Sheets cell values, calculated formulas, RAW literal text, formatting and frozen rows')
        call('append_spreadsheet_values', {'fileId': sheet, 'range': 'Data!A:C', 'values': [[7, 14, 'appended']]})
        assert call('read_spreadsheet_values', {'fileId': sheet, 'ranges': ['Data!A3:C3'], 'valueRenderOption': 'UNFORMATTED_VALUE'})['valueRanges'][0]['values'] == [[7, 14, 'appended']]
        copied = call('copy_worksheet', {'fileId': sheet, 'sheetId': 100, 'destinationSpreadsheetId': sheet})
        assert copied['sheetId'] != 100
        call('clear_spreadsheet_values', {'fileId': sheet, 'ranges': ['Data!A3:C3']})
        assert not call('read_spreadsheet_values', {'fileId': sheet, 'ranges': ['Data!A3:C3']})['valueRanges'][0].get('values')
        check('Sheets append, worksheet copy and range clearing')

        doc = create('create_document', {'title': 'Document fixture', 'parentId': folder})['id']
        call('batch_update_document', {'fileId': doc, 'requests': [{'insertText': {'location': {'index': 1}, 'text': 'Harnais document fixture\n'}}]})
        document = call('get_document', {'fileId': doc})
        assert document.get('tabs') and 'Harnais document fixture' in json.dumps(document)
        revision = document['revisionId']
        call('replace_document_text', {'fileId': doc, 'text': 'Harnais', 'replacement': 'Verified', 'requiredRevisionId': revision})
        assert 'Verified document fixture' in json.dumps(call('get_document', {'fileId': doc}))
        stale = client.request('tools/call', {'name': 'replace_document_text', 'arguments': {'fileId': doc, 'text': 'Verified', 'replacement': 'Stale', 'requiredRevisionId': revision}})
        assert stale.get('isError'), 'Docs accepted a stale revision'
        check('Docs insertion, all-tab read, replacement and stale-revision rejection')

        slides = create('create_presentation', {'title': 'Slides fixture', 'parentId': folder})['id']
        call('batch_update_presentation', {'fileId': slides, 'requests': [
            {'createSlide': {'objectId': 'fixture_slide'}},
            {'createShape': {'objectId': 'fixture_shape', 'shapeType': 'TEXT_BOX', 'elementProperties': {'pageObjectId': 'fixture_slide', 'size': {'width': {'magnitude': 300, 'unit': 'PT'}, 'height': {'magnitude': 80, 'unit': 'PT'}}, 'transform': {'scaleX': 1, 'scaleY': 1, 'translateX': 20, 'translateY': 20, 'unit': 'PT'}}}},
            {'insertText': {'objectId': 'fixture_shape', 'text': 'Harnais slide fixture'}}
        ]})
        presentation = call('get_presentation', {'fileId': slides})
        call('replace_presentation_text', {'fileId': slides, 'text': 'Harnais', 'replacement': 'Verified', 'pageObjectIds': ['fixture_slide'], 'requiredRevisionId': presentation['revisionId']})
        assert 'Verified slide fixture' in json.dumps(call('get_presentation', {'fileId': slides}))
        check('Slides creation, shapes, text and revision-controlled replacement')

        original = reader.workbook()
        changed = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(original)) as source, zipfile.ZipFile(changed, 'w', zipfile.ZIP_DEFLATED) as destination:
            for info in source.infolist():
                content = source.read(info.filename)
                if info.filename == 'xl/worksheets/sheet1.xml':
                    content = content.replace(b'<v>20</v>', b'<v>50</v>').replace(b'<v>42</v>', b'<v>72</v>')
                destination.writestr(info, content)
        revised = changed.getvalue()
        xlsx = create('create_file', {'title': 'Original.xlsx', 'parentId': folder, 'contentMimeType': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'base64Content': base64.b64encode(original).decode(), 'disableConversionToGoogleType': True})
        working = call('download_file_to_path', {'fileId': xlsx['id']})
        version = working['version']
        local = Path(working['localPath'])
        local_folders.append(local.parent)
        assert local.read_bytes() == original and 'base64Content' not in working
        local.write_bytes(revised)
        updated = call('replace_file_content', {'fileId': xlsx['id'], 'localPath': str(local), 'expectedVersion': version})
        assert updated['id'] == xlsx['id'] and updated['webViewLink'] == xlsx['webViewLink'] and updated['parents'] == [folder] and updated['name'] == 'Original.xlsx'
        assert base64.b64decode(call('download_file_content', {'fileId': xlsx['id']})['base64Content']) == revised
        content = call('read_file_content', {'fileId': xlsx['id']})['content']
        assert 'B1: 72' in content and 'SUM(B2:B3)' in content and 'Harnais hidden fixture' in content
        stale = client.request('tools/call', {'name': 'replace_file_content', 'arguments': {'fileId': xlsx['id'], 'base64Content': base64.b64encode(original).decode(), 'expectedVersion': version}})
        assert stale.get('isError'), 'Replacement accepted stale version'
        check('Excel replacement preserves ID, URL, filename, folder, formulas, hidden sheet and exact bytes; rejects stale preflight version')

        large = create('create_file', {'title': 'Large.txt', 'parentId': folder, 'textContent': 'Original', 'contentMimeType': 'text/plain', 'disableConversionToGoogleType': True})
        payload = b'Harnais upload fixture.\n' * 250_000
        assert len(payload) > 5 * 1024 * 1024
        call('replace_file_content', {'fileId': large['id'], 'base64Content': base64.b64encode(payload).decode()})
        assert base64.b64decode(call('download_file_content', {'fileId': large['id']})['base64Content']) == payload
        check('Resumable replacement over 5 MB preserves all bytes')

        if args.all_accounts:
            accounts = json.loads((Path.home() / '.harnais/accounts.json').read_text())['accounts']
            for index, account in enumerate(accounts):
                server = probe.config(account)[args.name]
                cmd = server['command']
                executable, arguments = (cmd[0], cmd[1:]) if isinstance(cmd, list) else (cmd, server.get('args', []))
                mcp = probe.MCP(executable, arguments, {**account.get('env', {}), **server.get('env', {})})
                try:
                    init(mcp)
                    assert {t['name'] for t in mcp.request('tools/list')['tools']} == names
                    cell = 'Data!A' + str(index + 10)
                    call('update_spreadsheet_values', {'fileId': sheet, 'data': [{'range': cell, 'values': [[index + 100]]}]}, mcp)
                    actual = call('read_spreadsheet_values', {'fileId': sheet, 'ranges': [cell], 'valueRenderOption': 'UNFORMATTED_VALUE'}, mcp)
                    assert actual['valueRanges'][0]['values'] == [[index + 100]]
                    assert 'Verified document fixture' in json.dumps(call('get_document', {'fileId': doc}, mcp))
                    assert 'Verified slide fixture' in json.dumps(call('get_presentation', {'fileId': slides}, mcp))
                    assert base64.b64decode(call('download_file_content', {'fileId': xlsx['id']}, mcp)['base64Content']) == revised
                    check(account['provider'] + ' ' + account['id'] + ': all tools, native write/read, Docs, Slides, XLSX')
                finally:
                    mcp.close()
    except Exception as failure:
        error = str(failure)
        print(json.dumps({'status': 'failed', 'error': error}), flush=True)
    finally:
        for file_id in reversed(created):
            try:
                call('trash_file', {'fileId': file_id})
                cleaned.append(file_id)
            except Exception:
                pass
        client.close()
        for folder in local_folders:
            import shutil
            shutil.rmtree(folder)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'checks': checks, 'created': created, 'trashed': cleaned, 'error': error}, indent=2) + '\n')
        args.output.chmod(0o600)
    return 0 if error is None and len(created) == len(cleaned) else 1


if __name__ == '__main__':
    raise SystemExit(main())

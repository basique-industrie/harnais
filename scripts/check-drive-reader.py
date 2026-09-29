#!/usr/bin/env python3
"""Exercise the shared Drive reader with private temporary files, then trash them.
Only fixture IDs and status are recorded; no existing Drive content or credentials.
"""
import argparse
import base64
import importlib.util
import io
import json
from pathlib import Path
import uuid
import zipfile

spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('probe-shared-connections.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def package(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, text in files.items():
            archive.writestr(name, text)
    return buffer.getvalue()


def workbook():
    return package({
        '[Content_Types].xml': '''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>''',
        '_rels/.rels': '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>''',
        'xl/workbook.xml': '''<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="First" sheetId="1" r:id="r1"/><sheet name="Hidden data" sheetId="2" state="hidden" r:id="r2"/></sheets></workbook>''',
        'xl/_rels/workbook.xml.rels': '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="r2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>''',
        'xl/worksheets/sheet1.xml': '''<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Harnais reader fixture</t></is></c><c r="B1"><f>SUM(B2:B3)</f><v>42</v></c></row><row r="2"><c r="B2"><v>20</v></c></row><row r="3"><c r="B3"><v>22</v></c></row></sheetData></worksheet>''',
        'xl/worksheets/sheet2.xml': '''<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="8"><c r="C8" t="inlineStr"><is><t>Harnais hidden fixture</t></is></c></row></sheetData></worksheet>''',
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--name', default='harnais-google-drive-personal')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--image', type=Path)
    parser.add_argument('--all-accounts', action='store_true')
    args = parser.parse_args()
    client = probe.MCP(args.binary, ['mcp', 'serve', args.name], {})
    created, checks, cleaned = [], [], []

    def call(tool, arguments):
        result = client.request('tools/call', {'name': tool, 'arguments': arguments})
        if result.get('isError'):
            raise RuntimeError(tool + ' failed: ' + result['content'][0]['text'])
        return json.loads(result['content'][0]['text'])

    def verify(label, mime, data, markers, convert=False):
        file = call('create_file', {'title': 'Harnais reader test ' + label + ' ' + str(uuid.uuid4()),
                    'contentMimeType': mime, 'base64Content': base64.b64encode(data).decode(),
                    'disableConversionToGoogleType': not convert})
        created.append(file['id'])
        read = call('read_file_content', {'fileId': file['id']})['content']
        assert all(marker.lower() in read.lower() for marker in markers), label + ' content mismatch'
        checks.append({'format': label, 'status': 'passed'})
        print(json.dumps(checks[-1]), flush=True)
        return file

    try:
        client.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'harnais-reader-check', 'version': '1'}})
        client.send({'method': 'notifications/initialized'})
        xlsx = workbook()
        verify('XLSX', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', xlsx, ['B1: 42', 'SUM(B2:B3)', 'Hidden data', 'C8: Harnais hidden fixture'])
        verify('Google Sheets', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', xlsx, ['SUM(B2:B3)', 'Hidden data', 'Harnais hidden fixture'], convert=True)
        verify('Google Docs', 'text/plain', b'Harnais document fixture', ['Harnais document fixture'], convert=True)
        verify('DOCX', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', package({'word/document.xml': '<w:document xmlns:w="urn:w"><w:p><w:r><w:t>Harnais Word fixture</w:t></w:r></w:p></w:document>'}), ['Harnais Word fixture'])
        verify('PPTX', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', package({'ppt/slides/slide1.xml': '<slide xmlns:a="urn:a"><a:p><a:r><a:t>Harnais slide fixture</a:t></a:r></a:p></slide>'}), ['Harnais slide fixture'])
        for ext, mime in [('ODT','text'), ('ODP','presentation')]:
            verify(ext, 'application/vnd.oasis.opendocument.' + mime, package({'content.xml': '<office:document xmlns:office="urn:office" xmlns:text="urn:text"><text:p>Harnais OpenDocument fixture</text:p></office:document>'}), ['Harnais OpenDocument fixture'])
        verify('ODS', 'application/vnd.oasis.opendocument.spreadsheet', package({'content.xml': '<document xmlns:table="urn:table" xmlns:text="urn:text"><table:table table:name="Budget"><table:table-row><table:table-cell table:formula="of:=1+2"><text:p>3</text:p></table:table-cell></table:table-row></table:table></document>'}), ['Budget','of:=1+2'])
        if args.image:
            verify('PNG OCR', 'image/png', args.image.read_bytes(), ['HARNAIS READER FIXTURE'])
        if args.all_accounts:
            accounts = json.loads((Path.home() / '.harnais/accounts.json').read_text())['accounts']
            for account in accounts:
                server = probe.config(account)[args.name]
                cmd = server['command']
                executable, arguments = (cmd[0], cmd[1:]) if isinstance(cmd, list) else (cmd, server.get('args', []))
                reader = probe.MCP(executable, arguments, {**account.get('env', {}), **server.get('env', {})})
                try:
                    reader.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'harnais-account-reader-check', 'version': '1'}})
                    reader.send({'method': 'notifications/initialized'})
                    reply = reader.request('tools/call', {'name': 'read_file_content', 'arguments': {'fileId': created[0]}})
                    assert not reply.get('isError'), 'Account reader failed'
                    content = json.loads(reply['content'][0]['text'])['content']
                    assert 'SUM(B2:B3)' in content and 'Harnais hidden fixture' in content, 'Account content mismatch'
                    checks.append({'accountID': account['id'], 'format': 'XLSX cells, formulas and hidden sheet', 'status': 'passed'})
                    print(json.dumps(checks[-1]), flush=True)
                finally:
                    reader.close()
        file = call('copy_file', {'fileId': created[0], 'title': 'Harnais reader copy fixture'})
        created.append(file['id'])
        call('update_file', {'fileId': file['id'], 'title': 'Harnais reader renamed fixture'})
        call('get_file_permissions', {'fileId': file['id']})
        assert base64.b64decode(call('download_file_content', {'fileId': file['id']})['base64Content']) == xlsx
        checks.append({'format': 'copy, rename, permissions, binary download', 'status': 'passed'})
    finally:
        for file_id in created:
            try:
                call('trash_file', {'fileId': file_id})
                cleaned.append(file_id)
            except Exception:
                pass
        client.close()
        args.output.write_text(json.dumps({'checks': checks, 'createdFixtures': len(created), 'trashedFixtures': len(cleaned), 'remainingFixtureIDs': [value for value in created if value not in cleaned]}, indent=2) + '\n')
        args.output.chmod(0o600)
        if len(created) != len(cleaned):
            raise RuntimeError('Fixture cleanup needs attention; inspect the local report')

if __name__ == '__main__':
    main()

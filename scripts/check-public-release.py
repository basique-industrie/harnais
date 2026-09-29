#!/usr/bin/env python3
"""Check distributable source without printing potential credentials."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
required = ['LICENSE', 'PRIVACY.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md',
            'CHANGELOG.md', 'Sources/HarnaisCore/Resources/PrivacyInfo.xcprivacy',
            'Helpers/WhatsAppBridge/THIRD_PARTY_LICENSES.txt']
errors = [f'Missing release file: {name}' for name in required if not (root / name).is_file()]
for name in ['Sources/HarnaisCore/Info.plist', 'Sources/HarnaisCore/Resources/PrivacyInfo.xcprivacy']:
    with (root / name).open('rb') as handle:
        plistlib.load(handle)
patterns = {
    'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'service token': r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[bpars]-[A-Za-z0-9-]{15,})',
    'personal absolute path': r'/Users/(?!you/|example/|test/|username/|x/)[^/\s]+/',
}
paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode().split('\0')
for name in set(paths):
    if not name or name == 'scripts/check-public-release.py':
        continue
    path = root / name
    try:
        content = path.read_text()
    except (UnicodeError, IsADirectoryError):
        continue
    for line, value in enumerate(content.splitlines(), 1):
        for label, pattern in patterns.items():
            if re.search(pattern, value):
                errors.append(f'{name}:{line}: possible {label}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
subprocess.run(['git', 'diff', '--check'], cwd=root, check=True)
subprocess.run(['git', 'diff', '--cached', '--check'], cwd=root, check=True)
print('Public-release checks passed.')

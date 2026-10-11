#!/usr/bin/env python3
"""Fail publication when a feed would downgrade builds or omit archive signatures."""
import argparse
import base64
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate(path, *, next_build=None, archive=None, build=None, version=None):
    raw = Path(path).read_bytes()
    feed_signature = re.search(rb'<!--\s*sparkle-signatures:\s*edSignature:\s*([A-Za-z0-9+/=]+)\s+length:\s*[0-9]+\s*-->', raw)
    if not feed_signature or len(base64.b64decode(feed_signature[1], validate=True)) != 64:
        raise ValueError('Appcast must contain its EdDSA feed signature')
    items = ET.fromstring(raw).findall('./channel/item')
    builds = [int(item.findtext(SPARKLE + 'version', '0')) for item in items]
    if next_build is not None and builds and next_build <= max(builds):
        raise ValueError('CFBundleVersion must increase beyond every published build')
    if archive is None:
        return
    matches = [item for item in items if item.findtext(SPARKLE + 'version') == str(build)]
    if len(matches) != 1:
        raise ValueError('Expected exactly one item for the new build')
    item = matches[0]
    if item.findtext(SPARKLE + 'shortVersionString') != version:
        raise ValueError('Appcast marketing version differs from the app')
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('Update archive is missing')
    signature = base64.b64decode(enclosure.attrib.get(SPARKLE + 'edSignature', ''), validate=True)
    if len(signature) != 64:
        raise ValueError('Update archive requires an EdDSA signature')
    expected = f'https://github.com/maclifevn/MClean/releases/download/v{version}/{Path(archive).name}'
    if enclosure.attrib.get('url') != expected:
        raise ValueError('Archive must use the matching official release URL')
    if int(enclosure.attrib.get('length', '0')) != Path(archive).stat().st_size:
        raise ValueError('Signed archive length does not match the final ZIP')
    if not item.findtext(SPARKLE + 'minimumSystemVersion'):
        raise ValueError('Missing minimum macOS version')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('feed')
    parser.add_argument('--next-build', type=int)
    parser.add_argument('--archive')
    parser.add_argument('--build', type=int)
    parser.add_argument('--version')
    args = parser.parse_args()
    try:
        validate(args.feed, next_build=args.next_build, archive=args.archive, build=args.build, version=args.version)
    except (ValueError, ET.ParseError, OSError) as error:
        parser.exit(1, f'Invalid appcast: {error}\n')

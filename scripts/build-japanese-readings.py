#!/usr/bin/env python3
"""Build the bundled Japanese word and character reading dictionary."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import unicodedata
import xml.etree.ElementTree as ET

RESOURCE = Path(__file__).resolve().parents[1] / 'Packages/StarryKit/Sources/LyricsCore/Resources/JapaneseReadings'
MAGIC = b'STJREAD\0'


def decode_kana(value):
    if not value or len(value) > 64 or any(c > 85 and c != 255 for c in value):
        raise ValueError('invalid encoded reading')
    return ''.join(chr(0x30FC if c == 255 else 0x3041 + c) for c in value)


def encode_kana(value):
    encoded = bytes(255 if c == 'ー' else ord(c) - 0x3041 for c in value)
    if decode_kana(encoded) != value:
        raise ValueError('reading cannot be encoded')
    return encoded


def read_index(data, purpose=1):
    if len(data) < 32 or data[:8] != MAGIC:
        raise ValueError('invalid indexed dictionary')
    version, word_version = struct.unpack_from('<II', data, 8)
    if version == 1:
        keys, entries, pool, length = struct.unpack_from('<4I', data, 16)
        header, stride = 32, 9
    elif version == 2 and len(data) >= 40:
        keys, entries, pool, length, reserved = struct.unpack_from('<5I', data, 20)
        if reserved:
            raise ValueError('unsupported header flags')
        header, stride = 40, 9
    else:
        raise ValueError('unsupported dictionary version')
    if pool != header + keys * 12 + entries * stride or pool > len(data) or length != len(data):
        raise ValueError('inconsistent dictionary layout')
    result = {}
    previous = b''
    for index in range(keys):
        offset, first, length, count = struct.unpack_from('<IIHH', data, header + index * 12)
        if not 0 < length <= 128 or pool + offset + length > len(data) or not 0 < count <= 128 or first + count > entries:
            raise ValueError('invalid key record')
        encoded_key = data[pool + offset:pool + offset + length]
        if encoded_key <= previous:
            raise ValueError('keys must be unique and sorted by UTF-8')
        previous = encoded_key
        values = []
        for entry in range(first, first + count):
            position = header + keys * 12 + entry * stride
            offset, parts, cost, length = struct.unpack_from('<IHhB', data, position)
            flags = parts >> 14 if version == 2 else 1
            if version == 2:
                if parts & 0x3C00:
                    raise ValueError('unsupported reading metadata bits')
                parts &= 1023
            if not 0 < flags <= 3 or pool + offset + length > len(data):
                raise ValueError('invalid reading record')
            if (flags & 1 and not 0 < parts <= 1023) or (not flags & 1 and (parts or cost)):
                raise ValueError('invalid word metadata')
            reading = decode_kana(data[pool + offset:pool + offset + length])
            if flags & purpose:
                values.append((reading, parts, cost))
        if values:
            result[encoded_key.decode('utf-8')] = values
    return word_version, result


def read_characters(archive):
    root = ET.fromstring(gzip.decompress(archive))
    readings = {}
    for entry in root.findall('character'):
        values = set()
        for node in entry.findall('./reading_meaning/rmgroup/reading'):
            if node.get('r_type') not in ('ja_on', 'ja_kun'):
                continue
            value = unicodedata.normalize('NFKC', node.text).split('.')[0].replace('-', '')
            value = ''.join(chr(ord(c) - 0x60) if 0x30A1 <= ord(c) <= 0x30F6 else c for c in value)
            if value and all(0x3041 <= ord(c) <= 0x3096 or c == 'ー' for c in value):
                values.add(value)
        if values:
            readings[entry.findtext('literal')] = sorted(values)
    return root.findtext('./header/date_of_creation'), root.findtext('./header/database_version'), readings


def encode_index(words, characters, word_version, character_version):
    pool, offsets = bytearray(), {}

    def intern(value):
        if value not in offsets:
            offsets[value] = len(pool)
            pool.extend(value)
        return offsets[value]

    keys, entries = bytearray(), bytearray()
    count = 0
    for key in sorted(words.keys() | characters.keys(), key=lambda key: key.encode('utf-8')):
        values = [[reading, parts, cost, 1] for reading, parts, cost in words.get(key, [])]
        by_reading = {value[0]: index for index, value in enumerate(values)}
        if len(by_reading) != len(values):
            raise ValueError('duplicate word reading')
        for reading in characters.get(key, []):
            if reading in by_reading:
                values[by_reading[reading]][3] |= 2
            else:
                values.append([reading, 0, 0, 2])
        encoded_key = key.encode('utf-8')
        if not 0 < len(encoded_key) <= 128 or not 0 < len(values) <= 128:
            raise ValueError('key exceeds the format bounds')
        keys.extend(struct.pack('<IIHH', intern(encoded_key), count, len(encoded_key), len(values)))
        for reading, parts, cost, flags in values:
            encoded = encode_kana(reading)
            entries.extend(struct.pack('<IHhB', intern(encoded), parts | flags << 14, cost, len(encoded)))
            count += 1
    pool_offset = 40 + len(keys) + len(entries)
    length = pool_offset + len(pool)
    header = struct.pack('<8s8I', MAGIC, 2, word_version, character_version, len(keys) // 12, count, pool_offset, length, 0)
    return header + keys + entries + pool


def word_fingerprint(words):
    canonical = json.dumps(words, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(canonical).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--word-index', type=Path, default=RESOURCE / 'readings.bin')
    parser.add_argument('--word-records-sha256', help='Expected canonical word snapshot identity')
    parser.add_argument('--kanjidic', type=Path, required=True, help='kanjidic2.xml.gz from EDRDG')
    parser.add_argument('--kanjidic-sha256', help='Expected KANJIDIC2 archive identity')
    parser.add_argument('--output', type=Path, default=RESOURCE)
    args = parser.parse_args()
    try:
        word_version, words = read_index(args.word_index.read_bytes())
        word_hash = word_fingerprint(words)
        if args.word_records_sha256 and word_hash != args.word_records_sha256:
            raise ValueError('word snapshot identity does not match --word-records-sha256')
        archive = args.kanjidic.read_bytes()
        archive_hash = hashlib.sha256(archive).hexdigest()
        if args.kanjidic_sha256 and archive_hash != args.kanjidic_sha256:
            raise ValueError('archive identity does not match --kanjidic-sha256')
        date, database, characters = read_characters(archive)
        data = encode_index(words, characters, word_version, int(date.replace('-', '')))
        if read_index(data)[1] != words:
            raise ValueError('merged word view differs from the original')
        expected = {key: [(value, 0, 0) for value in values] for key, values in characters.items()}
        actual = {key: sorted((reading, 0, 0) for reading, _, _ in values) for key, values in read_index(data, 2)[1].items()}
        if actual != expected:
            raise ValueError('merged character view differs from KANJIDIC2')
    except (OSError, ValueError, struct.error, ET.ParseError) as error:
        parser.error(str(error))
    provenance = {
        'format_version': 2,
        'generator': 'scripts/build-japanese-readings.py',
        'words': {'source': 'SudachiDict Core', 'version': str(word_version),
                  'url': f'https://github.com/WorksApplications/SudachiDict/tree/v{word_version}',
                  'records_sha256': word_hash, 'keys': len(words), 'readings': sum(map(len, words.values()))},
        'characters': {'source': 'KANJIDIC2', 'url': 'https://www.edrdg.org/kanjidic/kanjidic2.xml.gz',
                       'sha256': archive_hash, 'database_version': database, 'date': date,
                       'keys': len(characters), 'readings': sum(map(len, characters.values())),
                       'transformation': 'Japanese on/kun only; NFKC, hiragana, strip okurigana/affix markers; no nanori or exceptions'},
        'layout': {'header_bytes': 40, 'key_record_bytes': 12, 'reading_record_bytes': 9,
                   'metadata_bits': {'POS': '0..9', 'reserved_zero': '10..13', 'word': 14, 'character': 15},
                   'strings': 'Shared deduplicated pool; UTF-8 keys and one-byte kana',
                   'order': 'UTF-8 keys; original word reading order and metadata preserved'},
        'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
    }
    args.output.mkdir(parents=True, exist_ok=True)
    temporary = args.output / 'readings.bin.tmp'
    temporary.write_bytes(data)
    temporary.replace(args.output / 'readings.bin')
    (args.output / 'provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(provenance, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()

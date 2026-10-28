"""Validate a SCRIPTTRACE log and list static, symbol-matched Kismet call candidates.

This is not a full disassembler or evidence that a branch executed. Input is data;
no game code is executed and no pointers are dereferenced.
"""
import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import zlib

MAX_TOTAL = 262144
MAX_FUNCTION = 131072


@dataclass
class Script:
    path: str
    data: bytes


def parse_log(text):
    reports, symbols, scripts, active = [], {}, [], None
    started = False
    total = 0
    for raw in text.splitlines():
        if 'SCRIPTTRACE ' not in raw:
            continue
        line = raw.split('SCRIPTTRACE ', 1)[1]
        if line.startswith('REPORT-BEGIN '):
            if started:
                raise ValueError('Previous report is incomplete')
            if line != 'REPORT-BEGIN version=1 offset=0x60':
                raise ValueError('Unknown report version/layout')
            symbols, scripts, active, total, started = {}, [], None, 0, True
        elif not started:
            continue
        elif line.startswith('FN '):
            m = re.fullmatch(r'FN address=0x([0-9a-f]+) nameid=\d+ flags=0x[0-9a-f]+ path=(.+)', line)
            if not m:
                raise ValueError('Malformed function symbol')
            address, path = int(m[1], 16), m[2]
            if address in symbols and symbols[address] != path:
                raise ValueError('Conflicting function symbol')
            symbols[address] = path
        elif line.startswith('BEGIN '):
            m = re.fullmatch(r'BEGIN seq=(\d+) bytes=(\d+) address=0x[0-9a-f]+ path=(.+)', line)
            if not m or active:
                raise ValueError('Malformed or nested script')
            seq, size = int(m[1]), int(m[2])
            if seq != len(scripts) + 1 or not 0 < size <= MAX_FUNCTION or total + size > MAX_TOTAL:
                raise ValueError('Script sequence/size limit violated')
            active = (seq, size, m[3], bytearray())
        elif line.startswith('HEX '):
            m = re.fullmatch(r'HEX seq=(\d+) offset=(\d+) data=([0-9a-f]+)', line)
            if not m or not active or len(m[3]) % 2:
                raise ValueError('Malformed script bytes')
            seq, size, _, data = active
            if int(m[1]) != seq or int(m[2]) != len(data) or len(m[3]) > 256:
                raise ValueError('Noncontiguous/oversized script chunk')
            data.extend(bytes.fromhex(m[3]))
            if len(data) > size:
                raise ValueError('Script byte count exceeded')
        elif line.startswith('END '):
            m = re.fullmatch(r'END seq=(\d+) bytes=(\d+) adler32=([0-9a-f]{8})', line)
            if not m or not active:
                raise ValueError('Unexpected script end')
            seq, size, path, data = active
            if int(m[1]) != seq or int(m[2]) != size or len(data) != size:
                raise ValueError('Incomplete script bytes')
            if zlib.adler32(data) != int(m[3], 16) or data[-1] != 0x53:
                raise ValueError('Script checksum/EndOfScript mismatch')
            scripts.append(Script(path, bytes(data)))
            total += size
            active = None
        elif line.startswith('REPORT-END '):
            m = re.fullmatch(r'REPORT-END scripts=(\d+) bytes=(\d+); no script/item/save writes performed', line)
            if not m or active or not scripts or int(m[1]) != len(scripts) or int(m[2]) != total:
                raise ValueError('Incomplete report or totals mismatch')
            reports.append((symbols, scripts))
            started = False
        elif not line.startswith(('PROP ', 'SKIP ')):
            raise ValueError('Unknown report record')
    if started or active or not reports:
        raise ValueError('No complete report; preserve the log including SCRIPTTRACE errors')
    return reports


def static_calls(script, symbols):
    """Conservative byte-pattern candidates, not an instruction-boundary decoder."""
    getters = {'GetAbioticPlayerCharacter', 'GetPlayerCharacter', 'GetPlayerPawn',
               'GetPlayerController', 'GetPlayerCameraManager'}
    for offset in range(max(0, len(script.data) - 8)):
        opcode = script.data[offset]
        if opcode not in (0x68, 0x1c, 0x46):
            continue
        address = int.from_bytes(script.data[offset + 1:offset + 9], 'little')
        if address not in symbols:
            continue
        callee = symbols[address]
        tail = script.data[offset + 9:offset + 33]
        name = callee.rsplit(':', 1)[-1]
        zero = name in getters and any(tail.startswith(b'\x17' + literal + b'\x16')
                                      for literal in (b'\x25', b'\x1d\0\0\0\0', b'\x2c\0'))
        yield offset, callee, tail.hex(), zero


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('log', type=Path)
    args = cli.parse_args()
    if args.log.stat().st_size > 32 * 1024 * 1024:
        cli.error('Log exceeds 32 MiB')
    try:
        reports = parse_log(args.log.read_text(encoding='utf-8-sig', errors='replace'))
    except ValueError as error:
        cli.error(str(error))
    for number, (symbols, scripts) in enumerate(reports, 1):
        print(f'Report {number}: {len(scripts)} scripts, {sum(len(s.data) for s in scripts)} verified bytes')
        for script in scripts:
            print(script.path)
            for offset, callee, tail, zero in static_calls(script, symbols):
                print(f'  0x{offset:x} -> {callee}; next={tail}' +
                      ('; candidate Self / player index 0' if zero else ''))
    print('Static call candidates only; instruction boundaries and executed branches need separate verification.')


if __name__ == '__main__':
    main()

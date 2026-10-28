import importlib.util
from pathlib import Path
import sys
import unittest
import zlib

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('script_report', Path(__file__).resolve().parents[1] / 'tools/read_script_report.py')
report = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = report
spec.loader.exec_module(report)


def fixture(data=None):
    data = data if data is not None else b'\x68' + (0x12345678).to_bytes(8, 'little') + b'\x17\x25\x16\x53'
    return ('[log] SCRIPTTRACE REPORT-BEGIN version=1 offset=0x60\n'
            'SCRIPTTRACE FN address=0x12345678 nameid=2 flags=0x400 path=Function Lib:GetAbioticPlayerCharacter\n'
            f'SCRIPTTRACE BEGIN seq=1 bytes={len(data)} address=0x111 path=Function Widget:TakeAll\n'
            f'SCRIPTTRACE HEX seq=1 offset=0 data={data.hex()}\n'
            f'SCRIPTTRACE END seq=1 bytes={len(data)} adler32={zlib.adler32(data):08x}\n'
            f'SCRIPTTRACE REPORT-END scripts=1 bytes={len(data)}; no script/item/save writes performed\n')


class ScriptReportTests(unittest.TestCase):
    def test_symbol_matched_call_with_literal_zero(self):
        symbols, scripts = report.parse_log(fixture())[0]
        calls = list(report.static_calls(scripts[0], symbols))
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][-1])

    def test_unknown_pointer_and_different_getter_do_not_claim_zero(self):
        symbols, scripts = report.parse_log(fixture())[0]
        self.assertEqual(list(report.static_calls(scripts[0], {})), [])
        symbols[0x12345678] = 'Function Lib:Other'
        self.assertFalse(list(report.static_calls(scripts[0], symbols))[0][-1])

    def test_other_zero_encodings_and_opcodes(self):
        for opcode in (0x68, 0x1c, 0x46):
            for zero in (b'\x25', b'\x1d\0\0\0\0', b'\x2c\0'):
                data = bytes([opcode]) + (0x12345678).to_bytes(8, 'little') + b'\x17' + zero + b'\x16\x53'
                symbols, scripts = report.parse_log(fixture(data))[0]
                self.assertTrue(list(report.static_calls(scripts[0], symbols))[0][-1])

    def test_tampered_and_noncontiguous_bytes(self):
        for text in (fixture().replace('data=68', 'data=69'), fixture().replace('offset=0', 'offset=1')):
            with self.assertRaises(ValueError):
                report.parse_log(text)

    def test_truncation_and_duplicate_blocks(self):
        for text in (fixture().split('SCRIPTTRACE END')[0], fixture().split('SCRIPTTRACE REPORT-END')[0],
                     fixture().replace('SCRIPTTRACE END', 'SCRIPTTRACE REPORT-BEGIN version=1 offset=0x60\nSCRIPTTRACE END')):
            with self.assertRaises(ValueError):
                report.parse_log(text)

    def test_size_bounds_end_marker_and_totals(self):
        for text in (fixture().replace('BEGIN seq=1 bytes=13', 'BEGIN seq=1 bytes=131073'),
                     fixture(b'\x00'), fixture().replace('REPORT-END scripts=1', 'REPORT-END scripts=2')):
            with self.assertRaises(ValueError):
                report.parse_log(text)

    def test_multiple_complete_reports_are_separate(self):
        self.assertEqual(len(report.parse_log(fixture() + fixture())), 2)


if __name__ == '__main__':
    unittest.main()

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


SCAN_SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'scan-image.sh'

# Model Trivy's stdout/file output without requiring Docker or downloading a DB.
# Container-written files are made read-only to reproduce the runner's inability
# to overwrite root-owned files on Linux, including an empty clean-scan report.
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if args[0] == 'image':
    sys.exit(0)
if args[0] == 'save':
    Path(args[args.index('--output') + 1]).touch()
    sys.exit(0)
if os.environ['SCAN_CASE'] == 'error':
    sys.exit(42)
format_name = args[args.index('--format') + 1]
finding = os.environ['SCAN_CASE'] == 'finding'
output = {
    'json': json.dumps({'Results': [{'Vulnerabilities': [{'Severity': 'HIGH'}] if finding else []}]}),
    'sarif': json.dumps({'version': '2.1.0'}),
    'table': 'HIGH: test vulnerability\n' if finding else '',
}[format_name]
if '--output' in args:
    target = Path(os.environ['REPORT_DIR']) / Path(args[args.index('--output') + 1]).name
    target.write_text(output)
    target.chmod(0o444)
else:
    sys.stdout.write(output)
sys.exit(1 if finding and '--exit-code' in args and args[args.index('--exit-code') + 1] == '1' else 0)
'''


class ScanReportTests(unittest.TestCase):
    def run_scan(self, case):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        project = Path(temporary.name)
        (project / 'scripts').mkdir()
        script = project / 'scripts' / 'scan-image.sh'
        shutil.copyfile(SCAN_SCRIPT, script)
        docker = project / 'docker'
        docker.write_text(FAKE_DOCKER)
        docker.chmod(0o755)
        reports = project / 'reports'
        summary = project / 'step-summary.md'
        environment = dict(os.environ, SCAN_CASE=case, REPORT_DIR=str(reports),
                           GITHUB_STEP_SUMMARY=str(summary),
                           PATH=str(project) + os.pathsep + os.environ['PATH'])
        result = subprocess.run(['bash', str(script), 'test:image'], env=environment,
                                text=True, capture_output=True)
        return result, reports, summary

    def test_clean_scan_can_write_empty_report_and_publish_summary(self):
        result, reports, summary = self.run_scan('clean')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No HIGH or CRITICAL', (reports / 'trivy.txt').read_text())
        self.assertIn('PASS', summary.read_text())
        for name in ('trivy.json', 'trivy.sarif', 'trivy.txt'):
            self.assertTrue((reports / name).stat().st_mode & stat.S_IWUSR, name)
        json.loads((reports / 'trivy.json').read_text())
        json.loads((reports / 'trivy.sarif').read_text())

    def test_high_finding_still_fails_with_reports(self):
        result, reports, summary = self.run_scan('finding')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('HIGH: test vulnerability', (reports / 'trivy.txt').read_text())
        self.assertIn('FAIL', summary.read_text())
        self.assertNotIn('PASS', summary.read_text())

    def test_scanner_error_preserves_failure_status(self):
        result, _, summary = self.run_scan('error')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn('ERROR', summary.read_text())
        self.assertNotIn('PASS', summary.read_text())


if __name__ == '__main__':
    unittest.main()

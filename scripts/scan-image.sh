#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-mongo-express:local}"
# Trivy 0.76.2, pinned to the official multi-platform image digest.
scanner='aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb'
report_dir="${REPORT_DIR:-$project_dir/reports/security}"
mkdir -p "$report_dir" "$project_dir/.cache/trivy"
report_dir="$(cd -- "$report_dir" && pwd)"
scan_tmp="$(mktemp -d)"

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
finish() {
  status=$?
  if [[ ! -s "$report_dir/summary.md" ]]; then
    printf '%s\n' '**ERROR: the scan did not complete. No clean result is available.**' > "$report_dir/summary.md"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$report_dir/summary.md" >> "$GITHUB_STEP_SUMMARY"
  fi
  rm -rf "$scan_tmp"
  return "$status"
}
trap 'finish' EXIT
rm -f "$report_dir/trivy.json" "$report_dir/trivy.txt" "$report_dir/trivy.sarif" "$report_dir/summary.md"

# Archive the exact local image. The scanner never receives the Docker socket.
docker image inspect "$image" > /dev/null
docker save --output "$scan_tmp/image.tar" "$image"
scanner_args=(run --rm
  --mount "type=bind,src=$scan_tmp,dst=/scan,readonly"
  --mount "type=bind,src=$report_dir,dst=/reports"
  --mount "type=bind,src=$project_dir/.cache/trivy,dst=/root/.cache/trivy"
  "$scanner")

# Keep all severities in the reports; enforce the threshold during conversion.
# Scanner/database failures stop here, rather than producing a passing result.
docker "${scanner_args[@]}" image --config '' --input /scan/image.tar \
  --scanners vuln --pkg-types os,library --ignore-unfixed=false --ignorefile /dev/null \
  --format json --output /reports/trivy.json --exit-code 0 --timeout 15m
docker "${scanner_args[@]}" convert --config '' --scanners vuln --ignorefile /dev/null \
  --format sarif --output /reports/trivy.sarif /reports/trivy.json

scan_status=0
docker "${scanner_args[@]}" convert --config '' --scanners vuln --ignorefile /dev/null \
  --severity HIGH,CRITICAL --format table --table-mode detailed --output /reports/trivy.txt \
  --exit-code 1 /reports/trivy.json || scan_status=$?
if [[ "$scan_status" == 0 ]]; then
  if [[ ! -s "$report_dir/trivy.txt" ]]; then
    printf '%s\n' 'No HIGH or CRITICAL vulnerabilities detected.' > "$report_dir/trivy.txt"
  fi
  printf '%s\n' '**PASS: 0 HIGH and 0 CRITICAL vulnerabilities detected.**' > "$report_dir/summary.md"
else
  printf '%s\n' '**FAIL: HIGH/CRITICAL findings or a scan processing error. See the reports.**' > "$report_dir/summary.md"
fi
cat "$report_dir/trivy.txt"
{
  # shellcheck disable=SC2016 # Markdown backticks are literal.
  printf '\nImage: `%s`\n\nIncludes OS and application packages, fixed and unfixed findings, with no ignore list.\n\n```text\n' "$image"
  cat "$report_dir/trivy.txt"
  printf '\n```\n'
} >> "$report_dir/summary.md"
exit "$scan_status"

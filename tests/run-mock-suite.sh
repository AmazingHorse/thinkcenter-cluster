#!/usr/bin/env bash
# tests/run-mock-suite.sh — Offline mocked test suite runner for thinkcenter-cluster
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

just test

#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml"]
# ///
"""Unit tests for gather_lld_data.py."""
import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "gather_lld_data.py"
REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent.parent


def run_script(*args: str) -> tuple[int, str, str]:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True, text=True
    )
    return result.returncode, result.stdout, result.stderr


def test_valid_cluster():
    """Verify script produces valid JSON for an existing cluster."""
    code, stdout, stderr = run_script("--cluster", "etl6", "--repo-root", str(REPO_ROOT))
    assert code == 0, f"Script failed: {stderr}"
    data = json.loads(stdout)
    assert "cluster" in data
    assert "fleet" in data
    assert "nodes" in data
    assert "storage" in data
    assert "auth" in data
    assert "operators" in data
    assert data["cluster"]["cluster_name"] == "etl6"
    assert data["cluster"]["role"] == "managed"
    assert len(data["nodes"]) > 0
    print("PASS: test_valid_cluster")


def test_invalid_cluster():
    """Verify script returns error for nonexistent cluster."""
    code, stdout, stderr = run_script("--cluster", "nonexistent", "--repo-root", str(REPO_ROOT))
    assert code == 1, "Expected exit code 1 for invalid cluster"
    assert "not found" in stderr.lower() or "not found" in stdout.lower()
    print("PASS: test_invalid_cluster")


def test_hub_cluster():
    """Verify script handles hub cluster (dual-role) correctly."""
    code, stdout, stderr = run_script("--cluster", "hub", "--repo-root", str(REPO_ROOT))
    assert code == 0, f"Script failed: {stderr}"
    data = json.loads(stdout)
    assert data["cluster"]["role"] == "hub"
    assert len(data["cluster"].get("provisioned_clusters", [])) > 0
    print("PASS: test_hub_cluster")


def test_output_structure():
    """Verify all expected top-level keys are present."""
    code, stdout, stderr = run_script("--cluster", "etl6", "--repo-root", str(REPO_ROOT))
    assert code == 0
    data = json.loads(stdout)
    expected_keys = ["cluster", "fleet", "nodes", "install_nmstate", "day2_nmstate",
                     "storage", "auth", "cluster_version", "monitoring", "operators"]
    for key in expected_keys:
        assert key in data, f"Missing key: {key}"
    print("PASS: test_output_structure")


def test_node_fields():
    """Verify node entries have expected fields."""
    code, stdout, _ = run_script("--cluster", "etl6", "--repo-root", str(REPO_ROOT))
    assert code == 0
    data = json.loads(stdout)
    for node in data["nodes"]:
        assert "name" in node
        assert "hostname" in node
        assert "role" in node
        assert "bmc_address" in node
        assert "boot_mac" in node
    print("PASS: test_node_fields")


if __name__ == "__main__":
    test_valid_cluster()
    test_invalid_cluster()
    test_hub_cluster()
    test_output_structure()
    test_node_fields()
    print("\nAll tests passed.")

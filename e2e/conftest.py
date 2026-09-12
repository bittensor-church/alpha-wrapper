import os
import sys

_E2E_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(_E2E_DIR)

# Expose observability helpers to the chainless tests.
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

# cast/forge and the observability scripts are invoked with repo-relative paths
# (src/..., scripts/...). `import alpha_e2e` itself is resolved by
# `pythonpath = .` in pytest.ini.
os.chdir(_REPO_ROOT)
os.environ.setdefault("RUST_LOG", "error,alloy_provider::blocks=off")

pytest_plugins = ["alpha_e2e.fixtures"]

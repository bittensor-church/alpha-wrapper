import os

_E2E_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(_E2E_DIR)

# cast/forge and the observability scripts are invoked with repo-relative paths
# (src/..., scripts/...). `import alpha_e2e` itself is resolved by
# `pythonpath = .` in pytest.ini.
os.chdir(_REPO_ROOT)
os.environ.setdefault("RUST_LOG", "error,alloy_provider::blocks=off")

pytest_plugins = ["alpha_e2e.fixtures"]

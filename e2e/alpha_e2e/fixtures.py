"""Session-scoped pytest fixtures wrapping bootstrap.build_environment()."""
import pytest

from . import bootstrap


def pytest_addoption(parser):
    parser.addoption(
        "--registry-type", choices=("attested", "basic"), default="attested",
        help="Registry deployed by scenario fixtures (default: attested).",
    )


def pytest_generate_tests(metafunc):
    if "registry_type" in metafunc.fixturenames:
        metafunc.parametrize(
            "registry_type", [metafunc.config.getoption("--registry-type")], scope="session",
        )


@pytest.fixture(scope="session")
def recovery_window():
    """Scenarios may override the constructor window to observe expiry on a real chain."""
    return 3 * 60 * 60


@pytest.fixture(scope="session")
def env(recovery_window, registry_type):
    return bootstrap.build_environment(recovery_window=recovery_window, registry_type=registry_type)

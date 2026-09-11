"""Session-scoped pytest fixtures wrapping bootstrap.build_environment()."""
import pytest

from . import bootstrap


@pytest.fixture(scope="session")
def recovery_window():
    """Scenarios may override the constructor window to observe expiry on a real chain."""
    return 3 * 60 * 60


@pytest.fixture(scope="session")
def env(recovery_window):
    return bootstrap.build_environment(recovery_window=recovery_window)

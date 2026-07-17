"""Session-scoped pytest fixtures wrapping bootstrap.build_environment()."""
import pytest

from . import bootstrap


@pytest.fixture(scope="session")
def env():
    return bootstrap.build_environment()

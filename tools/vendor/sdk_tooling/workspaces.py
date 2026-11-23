"""Own and remove disposable workspaces used to execute SDK fixtures."""

import tempfile
import time
from contextlib import contextmanager
from pathlib import Path


def _cleanup_workspace(directory):
    # Bound the wait for Windows executable or DLL removal after process exit to 25.5 seconds.
    for delay in (0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 12.8):
        try:
            directory.cleanup()
        except PermissionError as error:
            if getattr(error, "winerror", None) not in {5, 32, 33}:
                raise
            time.sleep(delay)
        else:
            return
    directory.cleanup()


@contextmanager
def temporary_workspace(parent, *, prefix):
    """Own and remove one fresh workspace, allowing Windows file locks to clear."""
    directory = tempfile.TemporaryDirectory(dir=parent, prefix=prefix)
    try:
        yield Path(directory.name)
    except BaseException as error:
        try:
            _cleanup_workspace(directory)
        except OSError as cleanup_error:
            error.add_note(
                f"Could not remove temporary workspace {directory.name}: {cleanup_error}"
            )
        raise
    else:
        _cleanup_workspace(directory)

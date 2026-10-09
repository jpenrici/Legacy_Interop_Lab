"""legacy_ledger: Python bindings for the legacy COBOL ledger and its C++ extender.

    from legacy_ledger import Ledger
    ledger = Ledger()
    ledger.refresh()
    print(ledger.summary())

Pure Python (ctypes): no compiler and no third-party package needed. The Qt
adapter lives in ``legacy_ledger.qt`` and needs PySide6; it is not imported
here, so ``import legacy_ledger`` works without PySide6.
"""

from ._abi import AbiMismatchError, LibraryNotFoundError, Status
from .ledger import Ledger, LedgerError
from .models import (
    Month,
    Projection,
    RefreshResult,
    Snapshot,
    Summary,
    Year,
    bp_to_percent,
    cents_to_decimal,
    format_bp,
    format_cents,
)

__version__ = "0.1.0"

__all__ = [
    "AbiMismatchError",
    "Ledger",
    "LedgerError",
    "LibraryNotFoundError",
    "Month",
    "Projection",
    "RefreshResult",
    "Snapshot",
    "Status",
    "Summary",
    "Year",
    "bp_to_percent",
    "cents_to_decimal",
    "format_bp",
    "format_cents",
]

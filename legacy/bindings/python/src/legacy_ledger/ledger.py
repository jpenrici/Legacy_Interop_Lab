"""``Ledger``: the Python face of the COBOL ledger and its C++ extender.

    from legacy_ledger import Ledger

    ledger = Ledger()
    ledger.refresh()                 # runs the COBOL program once (a process)
    for month in ledger.months():    # then query as often as needed:
        print(month.period, month.balance, month.growth_pct)  # cheap, no process

* Errors are exceptions (``LedgerError``); a warning (some CSV lines were
  rejected) is not an error and is reported in ``RefreshResult.rejected``.
* ``refresh()`` blocks while COBOL runs. ctypes releases the GIL during the
  call, so a GUI can run it on a worker thread (see ``legacy_ledger.qt``).
"""

from __future__ import annotations

import ctypes
import os
from pathlib import Path
from typing import Callable, TypeVar

from . import _abi
from ._abi import Status
from .models import Month, Projection, RefreshResult, Snapshot, Summary, Year

T = TypeVar("T")

_LOG_SIZE = 4096


class LedgerError(Exception):
    """A call into the extender failed.

    ``status`` is the numeric code (a ``Status`` when it is a known one),
    ``log`` the output of the COBOL program when that is what failed.
    """

    def __init__(self, status: int, message: str, log: str = "") -> None:
        self.status: Status | int = _as_status(status)
        self.log = log
        super().__init__(f"{message} (status {int(status)})")


def _as_status(code: int) -> Status | int:
    try:
        return Status(code)
    except ValueError:
        return code


class Ledger:
    """Loads ``lib_legacy_extender.so`` once and exposes it as Python values."""

    def __init__(self, library: str | os.PathLike[str] | None = None) -> None:
        self.library_path: Path = _abi.find_library(library)
        self._lib = _abi.load_library(self.library_path)

    # --- information --------------------------------------------------------

    @property
    def version(self) -> str:
        """Version of the extender library, e.g. '0.1.0'."""
        return self._lib.lgx_version().decode()

    def strerror(self, status: int) -> str:
        return self._lib.lgx_strerror(int(status)).decode()

    @property
    def home(self) -> Path:
        """The legacy tree the library works on (``$LEGACY_HOME`` or its own)."""
        buffer = ctypes.create_string_buffer(4096)
        self._check(self._lib.lgx_home(buffer, len(buffer)))
        return Path(os.fsdecode(buffer.value))

    # --- running COBOL ------------------------------------------------------

    def refresh(self) -> RefreshResult:
        """Run the COBOL ledger. Raises ``LedgerError`` unless it succeeded
        (rejected input lines are a warning: see ``RefreshResult.rejected``)."""
        log = ctypes.create_string_buffer(_LOG_SIZE)
        status = self._lib.lgx_refresh(log, len(log))
        text = os.fsdecode(log.value)
        if status not in (Status.OK, Status.WARN_REJECTED):
            raise LedgerError(status, self.strerror(status), text)
        return RefreshResult(rejected=status == Status.WARN_REJECTED, log=text)

    # --- queries (read the .dat that the last refresh produced) -------------

    def months(self, window: int = 3) -> list[Month]:
        """The calendar series, months without entries filled in.
        ``window`` is the moving-average length in months (1..120)."""
        return self._fetch(
            self._lib.lgx_monthly_series, _abi.CMonth, Month.from_c, int(window)
        )

    def years(self) -> list[Year]:
        return self._fetch(self._lib.lgx_yearly_report, _abi.CYear, Year.from_c)

    def summary(self) -> Summary:
        out = _abi.CSummary()
        self._check(self._lib.lgx_ledger_summary(ctypes.byref(out)))
        return Summary.from_c(out)

    def project(self, basis_months: int = 3, horizon: int = 12) -> list[Projection]:
        """Carry the average balance of the last ``basis_months`` months flat
        for ``horizon`` months. A trend line for charts, not a forecast."""
        return self._fetch(
            self._lib.lgx_project,
            _abi.CProjection,
            Projection.from_c,
            int(basis_months),
            int(horizon),
        )

    def growth_bp(self, from_cents: int, to_cents: int) -> int:
        """(to - from) / |from| in basis points, rounded half away from zero."""
        out = ctypes.c_int64()
        self._check(self._lib.lgx_growth_bp(from_cents, to_cents, ctypes.byref(out)))
        return out.value

    def snapshot(
        self,
        *,
        refresh: bool = True,
        window: int = 3,
        basis_months: int = 3,
        horizon: int = 12,
    ) -> Snapshot:
        """Everything a screen shows, in one call. Safe to run on a worker thread."""
        result = self.refresh() if refresh else None
        return Snapshot(
            months=tuple(self.months(window)),
            years=tuple(self.years()),
            summary=self.summary(),
            projection=tuple(self.project(basis_months, horizon)),
            refresh=result,
        )

    # --- internals ----------------------------------------------------------

    def _check(self, status: int) -> None:
        if status != Status.OK:
            raise LedgerError(status, self.strerror(status))

    def _fetch(
        self,
        func: Callable[..., int],
        c_type: type[ctypes.Structure],
        convert: Callable[[ctypes.Structure], T],
        *leading: int,
    ) -> list[T]:
        """The C sizing protocol: ask for the size (max = 0), then fetch.

        The .dat may change between the two calls (a refresh in another
        thread); the second call then says CAPACITY again and we retry.
        """
        for _ in range(3):
            count = ctypes.c_size_t()
            status = func(*leading, None, 0, ctypes.byref(count))
            if status not in (Status.OK, Status.CAPACITY):
                raise LedgerError(status, self.strerror(status))
            wanted = count.value
            if wanted == 0:
                return []
            items = (c_type * wanted)()
            status = func(*leading, items, wanted, ctypes.byref(count))
            if status == Status.CAPACITY:
                continue
            self._check(status)
            return [convert(items[i]) for i in range(count.value)]
        raise LedgerError(Status.CAPACITY, "the ledger kept changing while it was read")

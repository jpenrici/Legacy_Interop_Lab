"""PySide6 adapter: the ledger as Qt models, refreshed off the GUI thread.

    from legacy_ledger.qt import LedgerController

    controller = LedgerController()               # owns a Ledger and 3 models
    table.setModel(controller.months_model)       # QTableView / QML
    controller.refreshed.connect(on_new_data)     # Snapshot
    controller.failed.connect(on_error)           # message, COBOL log
    controller.refresh_async()                    # never blocks the GUI

Only ``PySide6.QtCore`` is used: the models carry data and roles, the view
decides colours and fonts, so this module can be tested without a screen.

Roles of every model (besides ``DisplayRole``, the formatted text):

* ``RAW_ROLE``      the number behind the text (cents, basis points...), to sort
                    or to plot; ``None`` when undefined
* ``NEGATIVE_ROLE`` ``True`` for a negative amount: the view picks the colour
* ``GAP_ROLE``      (months only) ``True`` for a month filled in without entries
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Sequence

try:
    from PySide6.QtCore import (
        QAbstractTableModel,
        QModelIndex,
        QObject,
        QPersistentModelIndex,
        QRunnable,
        Qt,
        QThreadPool,
        Signal,
        Slot,
    )
except ImportError as exc:  # pragma: no cover - depends on the environment
    raise ImportError(
        "legacy_ledger.qt needs PySide6. Install it in the project venv with "
        "`perl bindings/python/builder.pl` (or: pip install -r "
        "bindings/python/requirements-qt.txt)"
    ) from exc

from .ledger import Ledger, LedgerError
from .models import Month, Projection, Snapshot, Year, format_bp, format_cents

RAW_ROLE = int(Qt.ItemDataRole.UserRole)
NEGATIVE_ROLE = RAW_ROLE + 1
GAP_ROLE = RAW_ROLE + 2

_RIGHT = Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
_LEFT = Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter


@dataclass(frozen=True)
class Column:
    """How one column reads a row: its header, text, raw value and alignment."""

    header: str
    text: Callable[[Any], str]
    raw: Callable[[Any], Any]
    numeric: bool = True  # right-aligned
    money: bool = False  # flagged through NEGATIVE_ROLE when below zero


def _money(header: str, field: str) -> Column:
    return Column(
        header,
        lambda r: format_cents(getattr(r, field)),
        lambda r: getattr(r, field),
        money=True,
    )


def _growth(header: str = "Growth") -> Column:
    return Column(header, lambda r: format_bp(r.growth_bp), lambda r: r.growth_bp)


def _count(header: str, field: str) -> Column:
    return Column(header, lambda r: str(getattr(r, field)), lambda r: getattr(r, field))


class TableModel(QAbstractTableModel):
    """A read-only table over a list of rows, described by ``Column``s."""

    def __init__(
        self, columns: Sequence[Column], parent: QObject | None = None
    ) -> None:
        super().__init__(parent)
        self._columns = tuple(columns)
        self._rows: list[Any] = []

    # --- content ------------------------------------------------------------

    def set_rows(self, rows: Sequence[Any]) -> None:
        """Replace everything (GUI thread only, like any model change)."""
        self.beginResetModel()
        self._rows = list(rows)
        self.endResetModel()

    def row_at(self, row: int) -> Any:
        return self._rows[row]

    # --- QAbstractTableModel ------------------------------------------------

    def rowCount(
        self, parent: QModelIndex | QPersistentModelIndex = QModelIndex()
    ) -> int:
        return 0 if parent.isValid() else len(self._rows)

    def columnCount(
        self, parent: QModelIndex | QPersistentModelIndex = QModelIndex()
    ) -> int:
        return 0 if parent.isValid() else len(self._columns)

    def data(
        self,
        index: QModelIndex | QPersistentModelIndex,
        role: int = Qt.ItemDataRole.DisplayRole,
    ) -> Any:
        if not index.isValid() or not (0 <= index.row() < len(self._rows)):
            return None
        column = self._columns[index.column()]
        row = self._rows[index.row()]
        if role == Qt.ItemDataRole.DisplayRole:
            return column.text(row)
        if role == Qt.ItemDataRole.TextAlignmentRole:
            return _RIGHT if column.numeric else _LEFT
        if role == RAW_ROLE:
            return column.raw(row)
        if role == NEGATIVE_ROLE:
            raw = column.raw(row)
            return bool(column.money and raw is not None and raw < 0)
        return self.extra_data(row, role)

    def extra_data(self, row: Any, role: int) -> Any:
        """Hook for subclasses: roles that depend on the row, not the column."""
        return None

    def headerData(
        self,
        section: int,
        orientation: Qt.Orientation,
        role: int = Qt.ItemDataRole.DisplayRole,
    ) -> Any:
        if role != Qt.ItemDataRole.DisplayRole:
            return None
        if orientation == Qt.Orientation.Horizontal:
            return self._columns[section].header
        return str(section + 1)

    def roleNames(self) -> dict[int, bytes]:  # names for QML
        names = dict(super().roleNames())
        names.update({RAW_ROLE: b"raw", NEGATIVE_ROLE: b"negative", GAP_ROLE: b"gap"})
        return names


class MonthsModel(TableModel):
    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(
            [
                Column("Month", lambda m: m.period, lambda m: m.period, numeric=False),
                _money("Debit", "debit_cents"),
                _money("Credit", "credit_cents"),
                _money("Balance", "balance_cents"),
                _money("Running", "cumulative_cents"),
                _money("Moving avg", "moving_avg_cents"),
                _growth(),
            ],
            parent,
        )

    def extra_data(self, row: Month, role: int) -> Any:
        return row.is_gap if role == GAP_ROLE else None


class YearsModel(TableModel):
    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(
            [
                Column("Year", lambda y: str(y.year), lambda y: y.year, numeric=False),
                _count("Months", "months"),
                _count("Entries", "entries"),
                _money("Debit", "debit_cents"),
                _money("Credit", "credit_cents"),
                _money("Balance", "balance_cents"),
                _money("Running", "cumulative_cents"),
                _money("Avg / month", "avg_monthly_cents"),
                _growth(),
            ],
            parent,
        )


class ProjectionModel(TableModel):
    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(
            [
                Column("Month", lambda p: p.period, lambda p: p.period, numeric=False),
                _money("Balance", "balance_cents"),
                _money("Running", "cumulative_cents"),
            ],
            parent,
        )


# --- refreshing without blocking the GUI -------------------------------------


class _Signals(QObject):
    """Carries a worker's result back to the GUI thread (queued connection)."""

    done = Signal(object)  # Snapshot
    failed = Signal(object)  # the exception


class _SnapshotTask(QRunnable):
    def __init__(
        self, ledger: Ledger, options: dict[str, int], signals: _Signals
    ) -> None:
        super().__init__()
        self._ledger, self._options, self._signals = ledger, options, signals

    def run(self) -> None:  # worker thread: no Qt widgets or models here
        try:
            snapshot = self._ledger.snapshot(**self._options)
        except Exception as exc:  # noqa: BLE001 - everything goes to the GUI
            self._signals.failed.emit(exc)
        else:
            self._signals.done.emit(snapshot)


class LedgerController(QObject):
    """Owns a ``Ledger`` and the three models; refreshes them on a worker thread."""

    refreshed = Signal(object)  # Snapshot, after the models were updated
    failed = Signal(str, str)  # message, COBOL log (may be empty)
    busy_changed = Signal(bool)

    def __init__(
        self,
        ledger: Ledger | None = None,
        *,
        window: int = 3,
        basis_months: int = 3,
        horizon: int = 12,
        parent: QObject | None = None,
    ) -> None:
        super().__init__(parent)
        self.ledger = ledger or Ledger()
        self._options = {
            "window": window,
            "basis_months": basis_months,
            "horizon": horizon,
        }
        self.months_model = MonthsModel(self)
        self.years_model = YearsModel(self)
        self.projection_model = ProjectionModel(self)
        self._snapshot: Snapshot | None = None
        self._busy = False

        # One refresh at a time, on a pool of its own (the global one stays free).
        self._pool = QThreadPool(self)
        self._pool.setMaxThreadCount(1)
        self._signals = _Signals(self)
        self._signals.done.connect(self._on_done)
        self._signals.failed.connect(self._on_failed)

    # --- state --------------------------------------------------------------

    @property
    def busy(self) -> bool:
        return self._busy

    @property
    def snapshot(self) -> Snapshot | None:
        """The last successful snapshot, or None before the first refresh."""
        return self._snapshot

    # --- actions ------------------------------------------------------------

    def refresh_async(self) -> bool:
        """Start a refresh on the worker thread. False if one is running."""
        if self._busy:
            return False
        self._set_busy(True)
        self._pool.start(_SnapshotTask(self.ledger, self._options, self._signals))
        return True

    def refresh_sync(self) -> Snapshot:
        """Blocking refresh in the calling thread (scripts, tests). Raises on error."""
        snapshot = self.ledger.snapshot(**self._options)
        self._apply(snapshot)
        return snapshot

    def wait(self, timeout_ms: int = 30000) -> bool:
        """Wait for a running worker to end (call it before the app quits)."""
        return self._pool.waitForDone(timeout_ms)

    # --- results (GUI thread) -----------------------------------------------

    def _apply(self, snapshot: Snapshot) -> None:
        self._snapshot = snapshot
        self.months_model.set_rows(snapshot.months)
        self.years_model.set_rows(snapshot.years)
        self.projection_model.set_rows(snapshot.projection)
        self.refreshed.emit(snapshot)

    @Slot(object)
    def _on_done(self, snapshot: Snapshot) -> None:
        self._set_busy(False)
        self._apply(snapshot)

    @Slot(object)
    def _on_failed(self, error: BaseException) -> None:
        self._set_busy(False)
        log = error.log if isinstance(error, LedgerError) else ""
        self.failed.emit(str(error), log)

    def _set_busy(self, busy: bool) -> None:
        if busy != self._busy:
            self._busy = busy
            self.busy_changed.emit(busy)

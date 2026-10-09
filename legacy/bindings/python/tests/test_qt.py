"""Tests of legacy_ledger.qt. Skipped when PySide6 is not installed.

Only QtCore is used, so no display is needed. The asynchronous tests run a real
event loop: they prove that a refresh happens on a worker thread and that its
result is delivered, by signal, to the thread that owns the models.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

try:
    from PySide6.QtCore import QCoreApplication, QEventLoop, QModelIndex, Qt, QTimer
except ImportError:  # pragma: no cover
    QCoreApplication = None

from legacy_ledger import Month

ROOT = Path(__file__).resolve().parents[3]  # legacy/
HAVE_QT = QCoreApplication is not None
SKIP_REASON = (
    "PySide6 is not installed (perl bindings/python/builder.pl installs it in the venv)"
)

if HAVE_QT:
    from legacy_ledger import qt as lq

    _app = QCoreApplication.instance() or QCoreApplication([])


def run_until(signal, start, timeout_ms=30000):
    """Run ``start()``, spin an event loop until ``signal`` fires. True if it did."""
    loop, fired = QEventLoop(), []
    signal.connect(lambda *args: (fired.append(args), loop.quit()))
    QTimer.singleShot(timeout_ms, loop.quit)
    start()
    if not fired:
        loop.exec()
    return fired


def month(period="2024-03", balance=-100, entries=1, growth=None):
    year, mon = map(int, period.split("-"))
    return Month(year, mon, 0, 100, balance, balance, balance, 1, entries, growth)


@unittest.skipUnless(HAVE_QT, SKIP_REASON)
class ModelTests(unittest.TestCase):
    """The models alone, with synthetic rows: no ledger involved."""

    def setUp(self):
        self.model = lq.MonthsModel()
        self.model.set_rows(
            [
                month("2024-01", balance=123456, growth=-453),
                month("2024-02", balance=-5, entries=0),
            ]
        )

    def at(self, row, column, role=None):
        # (the default is resolved here: without PySide6 this class body still runs, to be skipped)
        role = Qt.ItemDataRole.DisplayRole if role is None else role
        return self.model.index(row, column).data(role)

    def test_shape_and_headers(self):
        self.assertEqual((self.model.rowCount(), self.model.columnCount()), (2, 7))
        headers = [
            self.model.headerData(c, Qt.Orientation.Horizontal) for c in range(7)
        ]
        self.assertEqual(headers[:4], ["Month", "Debit", "Credit", "Balance"])
        self.assertEqual(self.model.headerData(0, Qt.Orientation.Vertical), "1")

    def test_display_text_is_formatted(self):
        self.assertEqual(self.at(0, 0), "2024-01")
        self.assertEqual(self.at(0, 3), "1,234.56")
        self.assertEqual(self.at(1, 3), "-0.05")
        self.assertEqual(self.at(0, 6), "-4.53%")
        self.assertEqual(self.at(1, 6), "")  # growth undefined

    def test_raw_values_for_sorting_and_charts(self):
        self.assertEqual(self.at(0, 3, lq.RAW_ROLE), 123456)
        self.assertEqual(self.at(0, 0, lq.RAW_ROLE), "2024-01")
        self.assertIsNone(self.at(1, 6, lq.RAW_ROLE))

    def test_view_hints_are_roles_not_colours(self):
        self.assertFalse(self.at(0, 3, lq.NEGATIVE_ROLE))
        self.assertTrue(self.at(1, 3, lq.NEGATIVE_ROLE))
        self.assertFalse(self.at(0, 6, lq.NEGATIVE_ROLE))  # growth is not money
        self.assertFalse(self.at(0, 0, lq.GAP_ROLE))
        self.assertTrue(self.at(1, 0, lq.GAP_ROLE))

    def test_alignment(self):
        align = Qt.ItemDataRole.TextAlignmentRole
        self.assertTrue(self.at(0, 3, align) & Qt.AlignmentFlag.AlignRight)
        self.assertTrue(self.at(0, 0, align) & Qt.AlignmentFlag.AlignLeft)

    def test_invalid_and_child_indexes_are_safe(self):
        self.assertIsNone(self.model.data(QModelIndex()))
        self.assertIsNone(self.model.index(9, 0).data())
        self.assertEqual(
            self.model.rowCount(self.model.index(0, 0)), 0
        )  # a table has no children

    def test_set_rows_resets_the_model(self):
        resets = []
        self.model.modelReset.connect(lambda: resets.append(1))
        self.model.set_rows([])
        self.assertEqual((self.model.rowCount(), len(resets)), (0, 1))

    def test_role_names_for_qml(self):
        names = self.model.roleNames()
        self.assertEqual(
            (names[lq.RAW_ROLE], names[lq.NEGATIVE_ROLE], names[lq.GAP_ROLE]),
            (b"raw", b"negative", b"gap"),
        )


@unittest.skipUnless(HAVE_QT, SKIP_REASON)
class ControllerTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("LEGACY_HOME", None)
        self.controller = lq.LedgerController(horizon=6)
        self.addCleanup(self.controller.wait)

    def test_refresh_sync_fills_the_three_models(self):
        snapshot = self.controller.refresh_sync()
        c = self.controller
        self.assertIs(c.snapshot, snapshot)
        self.assertEqual(
            (
                c.months_model.rowCount(),
                c.years_model.rowCount(),
                c.projection_model.rowCount(),
            ),
            (5, 2, 6),
        )
        self.assertEqual(c.months_model.index(1, 3).data(), "-489.35")
        self.assertTrue(c.months_model.index(1, 3).data(lq.NEGATIVE_ROLE))
        self.assertEqual(c.months_model.index(1, 6).data(), "-4.53%")
        self.assertEqual(c.years_model.index(1, 8).data(), "+116.48%")
        self.assertEqual(c.projection_model.index(0, 0).data(), "2024-04")

    def test_refresh_async_runs_off_the_gui_thread(self):
        c = self.controller
        seen_threads, busy_states = [], []
        c.busy_changed.connect(busy_states.append)
        original = c.ledger.refresh

        def spy():  # runs where the worker runs
            seen_threads.append(threading.current_thread())
            return original()

        c.ledger.refresh = spy  # type: ignore[method-assign]
        self.assertTrue(
            run_until(c.refreshed, lambda: self.assertTrue(c.refresh_async()))
        )

        self.assertEqual(len(seen_threads), 1)
        self.assertIsNot(
            seen_threads[0], threading.main_thread()
        )  # the COBOL call was not on the GUI thread
        self.assertEqual(busy_states, [True, False])
        self.assertFalse(c.busy)
        self.assertEqual(
            c.months_model.rowCount(), 5
        )  # models updated on this thread, from the signal
        self.assertEqual(c.snapshot.summary.months, 5)

    def test_a_second_refresh_while_busy_is_refused(self):
        c = self.controller
        started = []
        run_until(
            c.refreshed, lambda: started.extend([c.refresh_async(), c.refresh_async()])
        )
        self.assertEqual(started, [True, False])
        self.assertTrue(c.wait())

    def test_a_failure_is_a_signal_and_keeps_the_old_data(self):
        c = self.controller
        c.refresh_sync()  # good data first
        with tempfile.TemporaryDirectory(prefix="legacy_qt_") as tmp:
            for name in ("bin", "lib", "data"):
                shutil.copytree(ROOT / name, Path(tmp) / name, symlinks=True)
            (Path(tmp) / "data/input/cobol/cb_data.csv").unlink()
            os.environ["LEGACY_HOME"] = tmp
            fired = run_until(c.failed, c.refresh_async)
        self.assertTrue(fired)
        message, log = fired[0]
        self.assertIn("input CSV", message)
        self.assertIn("CANNOT OPEN INPUT", log)
        self.assertFalse(c.busy)
        self.assertEqual(
            c.months_model.rowCount(), 5
        )  # the previous data is still shown


if __name__ == "__main__":
    unittest.main()

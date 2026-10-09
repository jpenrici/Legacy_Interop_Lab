"""Tests of legacy_ledger (no PySide6 needed).

Part 1  formatting and models: pure Python
Part 2  the ABI: struct sizes, version, library discovery
Part 3  the real tree: COBOL -> bridge -> C++ extender -> Python
Part 4  scenarios on a COPY of the tree (LEGACY_HOME): errors, gaps, rejections

Run from legacy/bin, like every other test:  python -m unittest discover -s ../bindings/python/tests
"""

from __future__ import annotations

import ctypes
import ctypes.util
import dataclasses
import os
import shutil
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

from legacy_ledger import (
    AbiMismatchError,
    Ledger,
    LedgerError,
    LibraryNotFoundError,
    Month,
    Status,
    Summary,
    bp_to_percent,
    cents_to_decimal,
    format_bp,
    format_cents,
)
from legacy_ledger import _abi

ROOT = Path(__file__).resolve().parents[3]  # legacy/


class FormattingTests(unittest.TestCase):
    def test_cents_are_exact_decimals(self):
        self.assertEqual(cents_to_decimal(123456), Decimal("1234.56"))
        self.assertEqual(cents_to_decimal(-48935), Decimal("-489.35"))
        self.assertEqual(cents_to_decimal(5), Decimal("0.05"))
        self.assertEqual(bp_to_percent(11648), Decimal("116.48"))

    def test_format_cents(self):
        self.assertEqual(format_cents(-48935), "-489.35")
        self.assertEqual(format_cents(1234567), "12,345.67")
        self.assertEqual(format_cents(0), "0.00")
        self.assertEqual(format_cents(5), "0.05")

    def test_format_bp(self):
        self.assertEqual(format_bp(11648), "+116.48%")
        self.assertEqual(format_bp(-453), "-4.53%")
        self.assertEqual(format_bp(0), "0.00%")
        self.assertEqual(format_bp(None), "")

    def test_models_are_immutable(self):
        month = Month(2024, 3, 1, 0, 1, 1, 1, 1, 1, None)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            month.year = 1999  # type: ignore[misc]
        self.assertEqual(month.period, "2024-03")
        self.assertIsNone(month.growth_pct)


class AbiTests(unittest.TestCase):
    def test_struct_sizes_match_the_c_header(self):
        for struct, size in _abi.STRUCT_SIZES.items():
            self.assertEqual(ctypes.sizeof(struct), size, struct.__name__)
        _abi.check_layout()

    def test_library_and_version(self):
        ledger = Ledger()
        self.assertEqual(ledger.library_path.name, "lib_legacy_extender.so")
        self.assertEqual(ledger.version, "0.1.0")

    def test_strerror_is_never_empty(self):
        ledger = Ledger()
        for status in (*Status, 999, -999):
            self.assertTrue(ledger.strerror(status), status)

    def test_an_explicit_wrong_path_is_an_error_not_a_fallback(self):
        with self.assertRaises(LibraryNotFoundError) as caught:
            Ledger("/also/nonexistent.so")
        message = str(caught.exception)
        self.assertIn("/also/nonexistent.so", message)
        self.assertIn("perl extender/builder.pl", message)

    def test_the_env_override_is_exclusive_too(self):
        with mock.patch.dict(os.environ, {_abi.ENV_LIBRARY: "/nonexistent/lib.so"}):
            with self.assertRaises(LibraryNotFoundError) as caught:
                Ledger()
        self.assertIn("/nonexistent/lib.so", str(caught.exception))

    def test_automatic_search_falls_back_from_home_to_the_source_tree(self):
        with mock.patch.dict(os.environ, {_abi.ENV_HOME: "/nonexistent/tree"}):
            os.environ.pop(_abi.ENV_LIBRARY, None)
            self.assertEqual(Ledger().library_path, ROOT / "lib" / _abi.LIBRARY_NAME)

    def test_a_foreign_library_is_refused(self):
        # libc has none of the lgx_* functions: not our library
        with self.assertRaises(AttributeError):
            _abi.load_library(ctypes.util.find_library("c") or "libc.so.6")

    def test_version_mismatch_is_refused(self):
        with mock.patch.object(_abi, "EXPECTED_ABI", (9, 9)):
            with self.assertRaises(AbiMismatchError):
                Ledger()


class RealTreeTests(unittest.TestCase):
    """The shipped sample data: 2023-11 .. 2024-03, no gaps."""

    @classmethod
    def setUpClass(cls):
        with mock.patch.dict(os.environ):
            os.environ.pop("LEGACY_HOME", None)
            cls.ledger = Ledger()
            cls.result = cls.ledger.refresh()

    def test_refresh(self):
        self.assertFalse(self.result.rejected)
        self.assertIn("ACCEPTED=0000010", self.result.log)
        self.assertEqual(self.ledger.home, ROOT)

    def test_months(self):
        months = self.ledger.months()
        self.assertEqual(
            [m.period for m in months],
            ["2023-11", "2023-12", "2024-01", "2024-02", "2024-03"],
        )
        self.assertTrue(all(not m.is_gap for m in months))
        self.assertEqual(months[1].balance, Decimal("-489.35"))
        self.assertEqual(months[1].growth_bp, -453)  # -4.53%
        self.assertIsNone(months[0].growth_bp)  # nothing before the first month
        self.assertEqual(months[4].moving_avg_cents, 743995)
        self.assertEqual(months[4].window_used, 3)
        self.assertEqual(months[4].cumulative, Decimal("32630.00"))

    def test_window_changes_the_moving_average(self):
        self.assertEqual(self.ledger.months(window=1)[4].moving_avg_cents, 1101960)
        self.assertEqual(self.ledger.months(window=2)[4].window_used, 2)

    def test_years(self):
        years = self.ledger.years()
        self.assertEqual([y.year for y in years], [2023, 2024])
        self.assertIsNone(years[0].growth_bp)
        self.assertEqual(years[1].growth_bp, 11648)  # +116.48%
        self.assertEqual(years[1].growth_pct, Decimal("116.48"))
        self.assertEqual((years[0].months, years[1].months), (2, 3))

    def test_summary(self):
        summary = self.ledger.summary()
        self.assertIsInstance(summary, Summary)
        self.assertEqual((summary.months, summary.active_months), (5, 5))
        self.assertEqual(summary.avg_monthly_cents, 652600)
        self.assertEqual(
            (summary.best_period, summary.best_cents), ("2024-03", 1101960)
        )
        self.assertEqual(
            (summary.worst_period, summary.worst_cents), ("2023-12", -48935)
        )
        self.assertEqual(
            (summary.lines_read, summary.lines_accepted, summary.lines_rejected),
            (10, 10, 0),
        )
        self.assertEqual(summary.balance, Decimal("32630.00"))

    def test_projection(self):
        proj = self.ledger.project(basis_months=3, horizon=3)
        self.assertEqual([p.period for p in proj], ["2024-04", "2024-05", "2024-06"])
        self.assertEqual(proj[0].balance_cents, 743995)
        self.assertEqual(proj[2].cumulative_cents, 3263000 + 3 * 743995)
        self.assertEqual(
            self.ledger.project(3, 11)[-1].period, "2025-02"
        )  # 2024-03 + 11 months: rolls over the year

    def test_growth_helper(self):
        self.assertEqual(
            self.ledger.growth_bp(20000, 20001), 1
        )  # 0.5 rounds away from zero
        self.assertEqual(self.ledger.growth_bp(20000, 19999), -1)

    def test_snapshot_is_one_consistent_read(self):
        snapshot = self.ledger.snapshot(horizon=2)
        self.assertEqual(len(snapshot.months), 5)
        self.assertEqual(len(snapshot.years), 2)
        self.assertEqual(len(snapshot.projection), 2)
        self.assertFalse(snapshot.refresh.rejected)
        self.assertIsNone(self.ledger.snapshot(refresh=False).refresh)

    def test_argument_errors_are_exceptions(self):
        for call in (
            lambda: self.ledger.months(window=0),
            lambda: self.ledger.months(window=121),
            lambda: self.ledger.project(basis_months=0),
            lambda: self.ledger.project(horizon=999),
            lambda: self.ledger.growth_bp(0, 1),
        ):
            with self.assertRaises(LedgerError) as caught:
                call()
            self.assertEqual(caught.exception.status, Status.RANGE)
        with self.assertRaises(LedgerError) as caught:
            self.ledger.growth_bp(1, 2**63 - 1)
        self.assertEqual(caught.exception.status, Status.OVERFLOW)


class ScenarioTests(unittest.TestCase):
    """Each test runs the real COBOL on a private copy of the tree."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="legacy_py_")
        self.addCleanup(self._tmp.cleanup)
        self.tree = Path(self._tmp.name)
        for name in ("bin", "lib", "data"):
            shutil.copytree(ROOT / name, self.tree / name, symlinks=True)
        patcher = mock.patch.dict(os.environ, {"LEGACY_HOME": str(self.tree)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.csv = self.tree / "data/input/cobol/cb_data.csv"
        self.ledger = Ledger()

    def test_the_copy_is_what_runs(self):
        self.assertEqual(self.ledger.home, self.tree.resolve())

    def test_missing_input_is_an_error_with_the_cobol_log(self):
        self.csv.unlink()
        with self.assertRaises(LedgerError) as caught:
            self.ledger.refresh()
        self.assertEqual(caught.exception.status, Status.COBOL_INPUT)
        self.assertIn("CANNOT OPEN INPUT", caught.exception.log)

    def test_overflow_is_an_error(self):
        self.csv.write_text("2024-01-01,1,D,99999999999.99,a\n2024-01-02,1,D,1.00,b\n")
        with self.assertRaises(LedgerError) as caught:
            self.ledger.refresh()
        self.assertEqual(caught.exception.status, Status.COBOL_OVERFLOW)

    def test_rejected_lines_are_a_warning_not_an_error(self):
        self.csv.write_text(
            "2024-01-10,1,D,100.00,ok\n2024-02-30,1,D,50.00,bad day\n2024-01-20,1,C,40.25,ok\n"
        )
        result = self.ledger.refresh()
        self.assertTrue(result.rejected)
        self.assertIn("LINE 0000002 REJECTED", result.log)
        self.assertEqual(self.ledger.summary().lines_rejected, 1)
        self.assertEqual(
            self.ledger.months()[0].balance_cents, 5975
        )  # the valid lines count

    def test_months_without_entries_are_filled_in(self):
        self.csv.write_text("2024-01-10,1,D,100.00,a\n2024-04-05,1,C,40.00,b\n")
        self.ledger.refresh()
        months = self.ledger.months()
        self.assertEqual([m.entries for m in months], [1, 0, 0, 1])
        self.assertEqual([m.is_gap for m in months], [False, True, True, False])
        self.assertEqual(
            [m.cumulative_cents for m in months], [10000, 10000, 10000, 6000]
        )
        summary = self.ledger.summary()
        self.assertEqual(
            (summary.months, summary.active_months, summary.avg_monthly_cents),
            (4, 2, 1500),
        )

    def test_empty_ledger_has_no_data(self):
        self.csv.write_text("")
        self.assertFalse(self.ledger.refresh().rejected)
        for query in (self.ledger.months, self.ledger.years, self.ledger.summary):
            with self.assertRaises(LedgerError) as caught:
                query()
            self.assertEqual(caught.exception.status, Status.NO_DATA)

    def test_a_stale_dat_is_not_confused_with_a_fresh_one(self):
        self.ledger.refresh()
        self.assertEqual(len(self.ledger.months()), 5)
        self.csv.write_text("2025-06-01,1,D,10.00,only one\n")
        self.ledger.refresh()
        self.assertEqual([m.period for m in self.ledger.months()], ["2025-06"])


if __name__ == "__main__":
    unittest.main()

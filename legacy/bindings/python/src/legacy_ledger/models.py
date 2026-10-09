"""Plain, immutable Python values for what the ledger reports.

Everything is an ``int`` in cents or basis points, as the C ABI delivers it;
``Decimal`` views (``.balance``, ``.growth_pct``...) are exact, never floats.
A UI can show them directly and a model class can sort on the integers.

Growth is ``None`` when it is undefined (first period, or a zero base), so a
caller never has to know about the C ``growth_valid`` flag.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # only for type hints: this module does not need ctypes
    from . import _abi


def cents_to_decimal(cents: int) -> Decimal:
    """Exact: 123456 -> Decimal('1234.56')."""
    return Decimal(cents).scaleb(-2)


def bp_to_percent(bp: int) -> Decimal:
    """Basis points to percent, exact: 11648 -> Decimal('116.48')."""
    return Decimal(bp).scaleb(-2)


def format_cents(cents: int) -> str:
    """'-1,234.56' (USD amount, thousands separator, two decimals)."""
    return f"{cents_to_decimal(cents):,.2f}"


def format_bp(bp: int | None) -> str:
    """'+116.48%', '-4.53%', '0.00%'; '' when undefined (None)."""
    if bp is None:
        return ""
    return f"{bp_to_percent(bp):+,.2f}%" if bp else "0.00%"


def _growth(valid: int, bp: int) -> int | None:
    return bp if valid else None


@dataclass(frozen=True, slots=True)
class Month:
    """One CALENDAR month. ``entries == 0`` means no activity (filled in)."""

    year: int
    month: int
    debit_cents: int
    credit_cents: int
    balance_cents: int  # debit - credit of the month
    cumulative_cents: int  # running balance at the end of the month
    moving_avg_cents: int  # average monthly balance over ``window_used`` months
    window_used: int
    entries: int
    growth_bp: int | None  # running balance vs the previous month

    @classmethod
    def from_c(cls, c: "_abi.CMonth") -> "Month":
        return cls(
            c.year, c.month, c.debit_cents, c.credit_cents, c.balance_cents,
            c.cumulative_cents, c.moving_avg_cents, c.window_used, c.entries,
            _growth(c.growth_valid, c.growth_bp),
        )  # fmt: skip

    @property
    def period(self) -> str:
        return f"{self.year:04d}-{self.month:02d}"

    @property
    def is_gap(self) -> bool:
        return self.entries == 0

    @property
    def balance(self) -> Decimal:
        return cents_to_decimal(self.balance_cents)

    @property
    def cumulative(self) -> Decimal:
        return cents_to_decimal(self.cumulative_cents)

    @property
    def growth_pct(self) -> Decimal | None:
        return None if self.growth_bp is None else bp_to_percent(self.growth_bp)


@dataclass(frozen=True, slots=True)
class Year:
    year: int
    months: int  # calendar months of the series that fall in this year
    entries: int
    debit_cents: int
    credit_cents: int
    balance_cents: int
    cumulative_cents: int  # running balance at the end of the year
    avg_monthly_cents: int
    growth_bp: int | None  # balance vs the previous year

    @classmethod
    def from_c(cls, c: "_abi.CYear") -> "Year":
        return cls(
            c.year, c.months, c.entries, c.debit_cents, c.credit_cents,
            c.balance_cents, c.cumulative_cents, c.avg_monthly_cents,
            _growth(c.growth_valid, c.growth_bp),
        )  # fmt: skip

    @property
    def balance(self) -> Decimal:
        return cents_to_decimal(self.balance_cents)

    @property
    def growth_pct(self) -> Decimal | None:
        return None if self.growth_bp is None else bp_to_percent(self.growth_bp)


@dataclass(frozen=True, slots=True)
class Summary:
    debit_cents: int
    credit_cents: int
    balance_cents: int  # final running balance
    avg_monthly_cents: int
    best_cents: int
    best_year: int
    best_month: int
    worst_cents: int
    worst_year: int
    worst_month: int
    months: int  # calendar months in the series
    active_months: int  # months with entries
    lines_read: int
    lines_accepted: int
    lines_rejected: int

    @classmethod
    def from_c(cls, c: "_abi.CSummary") -> "Summary":
        return cls(
            c.debit_cents, c.credit_cents, c.balance_cents, c.avg_monthly_cents,
            c.best_cents, c.best_year, c.best_month,
            c.worst_cents, c.worst_year, c.worst_month,
            c.months, c.active_months, c.lines_read, c.lines_accepted, c.lines_rejected,
        )  # fmt: skip

    @property
    def best_period(self) -> str:
        return f"{self.best_year:04d}-{self.best_month:02d}"

    @property
    def worst_period(self) -> str:
        return f"{self.worst_year:04d}-{self.worst_month:02d}"

    @property
    def balance(self) -> Decimal:
        return cents_to_decimal(self.balance_cents)


@dataclass(frozen=True, slots=True)
class Projection:
    """A projected month: the recent average balance carried flat."""

    year: int
    month: int
    balance_cents: int
    cumulative_cents: int

    @classmethod
    def from_c(cls, c: "_abi.CProjection") -> "Projection":
        return cls(c.year, c.month, c.balance_cents, c.cumulative_cents)

    @property
    def period(self) -> str:
        return f"{self.year:04d}-{self.month:02d}"


@dataclass(frozen=True, slots=True)
class RefreshResult:
    """What running the COBOL ledger returned. ``log`` is its own output."""

    rejected: bool  # some input lines were rejected (data is still valid)
    log: str


@dataclass(frozen=True, slots=True)
class Snapshot:
    """Everything a screen needs, read in one go (see ``Ledger.snapshot``)."""

    months: tuple[Month, ...]
    years: tuple[Year, ...]
    summary: Summary
    projection: tuple[Projection, ...]
    refresh: RefreshResult | None  # None when the snapshot did not refresh

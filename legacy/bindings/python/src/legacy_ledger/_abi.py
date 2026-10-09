"""Low-level ctypes view of ``legacy_extender.h`` (lib/lib_legacy_extender.so).

Nothing here is meant to be used directly: ``legacy_ledger.Ledger`` wraps it.
This module only knows three things:

* WHERE the shared library is (``find_library``),
* the exact memory layout of the C structs (``CMonth`` ...), checked against
  the sizes the C header promises (``static_assert`` there, ``check_layout``
  here), so a library built from a different header is refused at load time,
* the signature of every ``lgx_*`` function (``load_library``), so ctypes
  checks arguments instead of guessing.

Money is integer cents everywhere, exactly as in the C header.
"""

from __future__ import annotations

import ctypes
import enum
import os
from pathlib import Path

#: ``lgx_version()`` major.minor this module was written for.
EXPECTED_ABI = (0, 1)

LIBRARY_NAME = "lib_legacy_extender.so"
ENV_LIBRARY = "LEGACY_EXTENDER_LIB"  # full path of the shared library
ENV_HOME = "LEGACY_HOME"  # a legacy tree: <home>/lib/lib_legacy_extender.so


class Status(enum.IntEnum):
    """``enum lgx_status``: 0..4 and -1..-8 come from the C bridge."""

    OK = 0
    COBOL_INPUT = 1
    COBOL_OUTPUT = 2
    WARN_REJECTED = 3
    COBOL_OVERFLOW = 4
    NOT_FOUND = -1
    SPAWN = -2
    SIGNAL = -3
    DATA = -4
    ARG = -5
    CAPACITY = -6
    HOME = -7
    UNEXPECTED = -8
    NO_DATA = -20
    OVERFLOW = -21
    RANGE = -22


class LibraryNotFoundError(FileNotFoundError):
    """lib_legacy_extender.so was not found; the message lists where we looked."""


class AbiMismatchError(RuntimeError):
    """The shared library does not match this module (version or struct size)."""


# --- struct layouts: field order and types are those of legacy_extender.h ---

_I64, _I32 = ctypes.c_int64, ctypes.c_int32


class CMonth(ctypes.Structure):
    _fields_ = [
        ("debit_cents", _I64),
        ("credit_cents", _I64),
        ("balance_cents", _I64),
        ("cumulative_cents", _I64),
        ("moving_avg_cents", _I64),
        ("growth_bp", _I64),
        ("year", _I32),
        ("month", _I32),
        ("entries", _I32),
        ("window_used", _I32),
        ("growth_valid", _I32),
        ("pad", _I32),
    ]


class CYear(ctypes.Structure):
    _fields_ = [
        ("debit_cents", _I64),
        ("credit_cents", _I64),
        ("balance_cents", _I64),
        ("cumulative_cents", _I64),
        ("avg_monthly_cents", _I64),
        ("growth_bp", _I64),
        ("year", _I32),
        ("months", _I32),
        ("entries", _I32),
        ("growth_valid", _I32),
    ]


class CSummary(ctypes.Structure):
    _fields_ = [
        ("debit_cents", _I64),
        ("credit_cents", _I64),
        ("balance_cents", _I64),
        ("avg_monthly_cents", _I64),
        ("best_cents", _I64),
        ("worst_cents", _I64),
        ("best_year", _I32),
        ("best_month", _I32),
        ("worst_year", _I32),
        ("worst_month", _I32),
        ("months", _I32),
        ("active_months", _I32),
        ("lines_read", _I32),
        ("lines_accepted", _I32),
        ("lines_rejected", _I32),
        ("pad", _I32),
    ]


class CProjection(ctypes.Structure):
    _fields_ = [
        ("balance_cents", _I64),
        ("cumulative_cents", _I64),
        ("year", _I32),
        ("month", _I32),
    ]


#: Sizes promised by the C header (``static_assert``s in legacy_extender.h).
STRUCT_SIZES = {CMonth: 72, CYear: 64, CSummary: 88, CProjection: 24}


def check_layout() -> None:
    """Raise ``AbiMismatchError`` if a struct is not the size the header says."""
    for struct, expected in STRUCT_SIZES.items():
        if ctypes.sizeof(struct) != expected:
            raise AbiMismatchError(
                f"{struct.__name__} is {ctypes.sizeof(struct)} bytes here, "
                f"the C header says {expected}"
            )


# --- finding and loading the library ---------------------------------------


def candidate_paths(explicit: str | os.PathLike[str] | None = None) -> list[Path]:
    """Where the library may be, in the order they are tried.

    A path asked for explicitly (the ``explicit`` argument, else
    ``$LEGACY_EXTENDER_LIB``) is the ONLY candidate: if it is wrong the caller
    must hear about it, not silently get another library. Without one, the
    automatic search is ``$LEGACY_HOME/lib`` and then the source tree.
    """
    if explicit:
        return [Path(explicit)]
    if os.environ.get(ENV_LIBRARY):
        return [Path(os.environ[ENV_LIBRARY])]
    found: list[Path] = []
    if os.environ.get(ENV_HOME):
        found.append(Path(os.environ[ENV_HOME]) / "lib" / LIBRARY_NAME)
    # Source-tree layout: <root>/bindings/python/src/legacy_ledger/_abi.py
    found.append(Path(__file__).resolve().parents[4] / "lib" / LIBRARY_NAME)
    return found


def find_library(explicit: str | os.PathLike[str] | None = None) -> Path:
    """First existing candidate, or ``LibraryNotFoundError`` listing them all."""
    tried = candidate_paths(explicit)
    for path in tried:
        if path.is_file():
            return path
    listing = "\n  ".join(str(p) for p in tried)
    raise LibraryNotFoundError(
        f"{LIBRARY_NAME} not found. Looked at:\n  {listing}\n"
        f"Build it with: perl extender/builder.pl  "
        f"(or set {ENV_LIBRARY} / {ENV_HOME})"
    )


def load_library(path: str | os.PathLike[str]) -> ctypes.CDLL:
    """Load the library, declare every ``lgx_*`` signature, check the ABI."""
    check_layout()
    # RTLD_LOCAL (the default): its symbols never leak into other libraries.
    lib = ctypes.CDLL(str(path))

    size_p = ctypes.POINTER(ctypes.c_size_t)
    signatures = {
        "lgx_version": (ctypes.c_char_p, []),
        "lgx_strerror": (ctypes.c_char_p, [ctypes.c_int]),
        "lgx_home": (ctypes.c_int, [ctypes.c_char_p, ctypes.c_size_t]),
        "lgx_refresh": (ctypes.c_int, [ctypes.c_char_p, ctypes.c_size_t]),
        "lgx_monthly_series": (
            ctypes.c_int,
            [_I32, ctypes.POINTER(CMonth), ctypes.c_size_t, size_p],
        ),
        "lgx_yearly_report": (
            ctypes.c_int,
            [ctypes.POINTER(CYear), ctypes.c_size_t, size_p],
        ),
        "lgx_ledger_summary": (ctypes.c_int, [ctypes.POINTER(CSummary)]),
        "lgx_project": (
            ctypes.c_int,
            [_I32, _I32, ctypes.POINTER(CProjection), ctypes.c_size_t, size_p],
        ),
        "lgx_growth_bp": (ctypes.c_int, [_I64, _I64, ctypes.POINTER(_I64)]),
    }
    for name, (restype, argtypes) in signatures.items():
        func = getattr(lib, name)  # AttributeError = not our library
        func.restype = restype
        func.argtypes = argtypes

    version = lib.lgx_version().decode()
    major_minor = tuple(int(part) for part in version.split(".")[:2])
    if major_minor != EXPECTED_ABI:
        raise AbiMismatchError(
            f"{path} is extender {version}; this binding expects "
            f"{EXPECTED_ABI[0]}.{EXPECTED_ABI[1]}.x"
        )
    return lib

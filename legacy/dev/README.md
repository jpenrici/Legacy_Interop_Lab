# Legacy ledger: developer guide

A monthly general ledger written in **COBOL**, reachable from modern code through a **C** bridge, a **C++23** extender and thin **language bindings**. The business is deliberately small; the point of the project is the *integration*: how a legacy program, a C ABI and several languages fit together without a build system nobody understands.

This file is for people who work on the project, and especially for people who want to **try another language** on top of it (section 9).

- [1. The pipeline at a glance](#1-the-pipeline-at-a-glance)
- [2. Directory map](#2-directory-map)
- [3. Layer by layer](#3-layer-by-layer)
- [4. The extender ABI (what is visible)](#4-the-extender-abi-what-is-visible)
- [5. Portability: why the tree can be moved](#5-portability-why-the-tree-can-be-moved)
- [6. The builder contract (`builder.pl`)](#6-the-builder-contract-builderpl)
- [7. The manifest (`Components.pm`)](#7-the-manifest-componentspm)
- [8. The rest of `dev/`](#8-the-rest-of-dev)
- [9. Trying another language](#9-trying-another-language)

## Quick start

```bash
perl dev/setup.pl check              # read-only: what is installed, missing, deviating
perl dev/setup.pl all                # check, build every component, run every test
perl dev/setup.pl run lua_tests      # one test by name (see "run" in the manifest)
LEGACY_NO_QT=1 perl dev/setup.pl all # everything, without downloading PySide6
perl dev/setup.pl prepare            # install what is missing (apt, GnuCOBOL in /opt)
perl dev/setup.pl --help             # all options
```

Build, run and clean **never need root** and refuse to run as root. Only `prepare` can need privileges (apt, `/opt`); it asks for them itself (section 8).

---

## 1. The pipeline at a glance

```
 data/input/cobol/cb_data.csv  the only input you edit!
        │   YYYY-MM-DD,ACCOUNT,D|C,AMOUNT,DESCRIPTION
        ▼
 ┌──────────────────────────┐  exit code 0..4
 │ bin/cobol_app            │  COBOL (GnuCOBOL translates to C, GCC 13 compiles)
 └──────────────────────────┘
        │   fixed-width records: M (month), Y (year), T (trailer)
        ▼
 data/store/cobol/cb_data.dat
        │
        ▼
 ┌──────────────────────────┐  lg_*   plain C
 │ lib/lib_c_api.so         │  runs cobol_app, parses the .dat, integer cents
 └──────────────────────────┘
        │   lg_record[], lg_summary
        ▼
 ┌──────────────────────────┐  lgx_*  C ABI, implemented in C++23
 │ lib/lib_cpp_api.so       │  calendar series, moving average, growth,
 └──────────────────────────┘  yearly report, summary, projection
        │                 │
        ▼                 ▼
 bindings/python    bindings/lua     bindings/<yours>  ...   ui (future)
```

| Layer | Language | Artifact | Contract with the next layer |
|---|---|---|---|
| COBOL ledger | COBOL | `bin/cobol_app` | CSV in, `.dat` out, exit code |
| C bridge | C17 | `lib/lib_c_api.so` | `lg_*` functions, `bridge.h` |
| C++ extender | C++23 | `lib/lib_cpp_api.so` | `lgx_*` functions, `extender.h` |
| Python bindings | Python 3.10+ | `bindings/python/.venv` | imports `legacy_ledger` |
| Lua bindings | C + Lua 5.4 | `bin/dist/lua/` | `require("binding")` |

The rule that keeps this manageable: **each layer knows only the contract of the layer below.** The bridge never links libcob (it starts the executable); the extender never reads the `.dat` (it asks the bridge); a binding never touches COBOL or the bridge (it calls `lgx_*` only).

---

## 2. Directory map

```
legacy/
├── cobol/            ledger.cob (the legacy program), builder.pl
├── bridge/           bridge.h, bridge.c, tests/, CMakeLists.txt, builder.pl
├── extender/         include/extender.h (C ABI) and .hpp (C++),
│                     src/ (extender.cpp, extender_analytics.cpp, extender_ffi.cpp), tests/
├── bindings/
│   ├── python/       src/legacy_ledger/, tests/, examples/, requirements-qt.txt, builder.pl
│   ├── lua/          src/ (module in C + API in Lua), tests/main.lua, CMakeLists.txt, builder.pl
│   └── others/       location for other directories, sources, and integration with user interfaces (UI)
├── dev/              this directory: tooling, no product code
│   ├── setup.pl      the one command (thin: reads the command line)
│   ├── LegacyDev.pm  shared helpers (messages, safe exec, privileges, apt)
│   ├── LegacyDev/    Components.pm (manifest), Check.pm, Pipeline.pm
│   ├── prepare_legacy_env.pl, gnucobol_install.pl     machine level, may need root
│   └── README.md
├── bin/              executables, and bin/dist/<language>/ for native modules
├── lib/              shared libraries (the bundled libcob/libgmp live here too)
└── data/             input/cobol/cb_data.csv, store/cobol/cb_data.dat, backup/
```

**The portable part is `bin/`, `lib/` and `data/`**: copy those three directories (no sources) to another machine of the same architecture and the executables and tests run (section 5). Everything else is source or tooling.

---

## 3. Layer by layer

### 3.1 COBOL ledger

`cobol/src/ledger.cob`, fixed-format, GnuCOBOL 3.1.2 (verified) or 3.2. Run from `legacy/bin` (its paths are relative to it).

**Input** `data/input/cobol/cb_data.csv`: one line per entry, `YYYY-MM-DD,ACCOUNT,D|C,AMOUNT,DESCRIPTION`. Chronological, no quotes, no commas in text. Invalid lines are rejected with a reason on stderr; the rest is processed.

**Output** `data/store/cobol/cb_data.dat`, `LINE SEQUENTIAL`, fixed width:

| Record | Bytes | Fields (1-based columns) |
|---|---|---|
| `M` month, `Y` year | 74 | 1 type · 2-5 year · 6-7 month · 8-22 debit · 23-37 credit · 38-52 balance · 53-67 cumulative · 68-74 entries |
| `T` trailer | 67 | 1 type · 2-8 read · 9-15 accepted · 16-22 rejected · 23-37 debit · 38-52 credit · 53-67 balance |

Money fields are `-99999999999.99` (sign, 11 digits, dot, 2 decimals): decimal exact, no floating point anywhere. Only months *with entries* get an `M` record.

**Exit code** of `cobol_app`:

| Code | Meaning | A success? |
|---|---|---|
| 0 | all lines accepted | yes |
| 1 | cannot open the input CSV | **no** |
| 2 | cannot write the `.dat` | **no** |
| 3 | done, some lines were rejected | yes (a *warning*: data is valid) |
| 4 | amount overflow, run aborted (`.dat` is partial) | **no** |

### 3.2 C bridge (`lib_c_api.so`, `lg_*`)

Starts `cobol_app` (fork/exec, never a shell), waits, parses the `.dat` into structs, validates layout, trailer and totals. It does **not** link libcob: the contract with COBOL is exit code plus file layout.

| Function | Purpose |
|---|---|
| `lg_version`, `lg_strerror(status)` | version, text for a status |
| `lg_home(buf, size)` | the resolved tree (`<home>`) |
| `lg_run(log, log_size)` | run `cobol_app` (cwd `<home>/bin`), capture its output; returns its exit code or a negative error |
| `lg_load(out, max, &count, &summary)` | parse the `.dat` into `lg_record[]` (48 bytes each) and `lg_summary` (40) |
| `lg_process(...)` | `lg_run` then `lg_load`; loads only when the run succeeded |
| `lg_format_cents(cents, buf, size)` | `"-1234.56"` |

`<home>` is `$LEGACY_HOME` if set, else two directories above `lib_c_api.so` (found with `dladdr`): the tree is located from where the library *is*, not from where it was built.

### 3.3 C++ extender (`lib_cpp_api.so`, `lgx_*`)

What COBOL and the bridge do not provide, written once so every language gets it:

- a **calendar series**: months without entries are filled in, so averages and growth are not skewed by missing months;
- moving average, month-over-month growth;
- a yearly report with year-over-year growth;
- a summary (totals, average, best and worst month);
- a flat projection of the running balance;
- an **independent audit** of what COBOL wrote (see "integrity checks" below).

Inside it is two parts (see `extender/CMakeLists.txt`):

1. `extender_core`, a **static** C++23 library: `Legacy::LedgerClient` (talks to the bridge) and `Legacy::Analytics` (pure functions, no I/O, testable with synthetic data), using `std::expected`.
2. `lib_cpp_api.so`: a thin `extern "C"` facade (`src/extender_ffi.cpp`) that links the core statically and exports **only** the nine `lgx_*` functions. The C++ runtime is linked statically and hidden (`--exclude-libs,ALL`), so the library depends only on libc and `lib_c_api.so`, and cannot clash with another C++ runtime in the same process (a Python interpreter, for instance).

C++ types never cross the boundary: only the flat structs and ints of `extender.h`. No exception escapes any `lgx_*` function.

---

## 4. The extender ABI (what is visible)

The contract is `extender/include/extender.h`. It is plain C, so any language with an FFI can use it. `nm -D --defined-only lib/lib_cpp_api.so` lists exactly these nine symbols and nothing else.

### 4.1 Functions

| Function | Purpose | Returns |
|---|---|---|
| `const char *lgx_version(void)` | library version, `"0.1.0"` | static string |
| `const char *lgx_strerror(int status)` | text for any status code | never `NULL` |
| `int lgx_home(char *buf, size_t size)` | resolved legacy tree | `OK`, `CAPACITY` (buffer too small), `ARG`, `HOME` |
| `int lgx_refresh(char *log, size_t log_size)` | run the COBOL program; `log` gets its output | `OK`, `WARN_REJECTED`, or an error (see 4.3) |
| `int lgx_monthly_series(int32_t window, lgx_month *out, size_t max, size_t *count)` | calendar series; `window` 1..120 | `OK`, `CAPACITY`, `RANGE`, `NO_DATA`, `DATA`, ... |
| `int lgx_yearly_report(lgx_year *out, size_t max, size_t *count)` | one entry per calendar year | same |
| `int lgx_ledger_summary(lgx_summary *out)` | whole-ledger summary | `OK`, `ARG`, `NO_DATA`, ... |
| `int lgx_project(int32_t basis_months, int32_t horizon, lgx_projection *out, size_t max, size_t *count)` | flat projection; both 1..120 | `OK`, `CAPACITY`, `RANGE`, ... |
| `int lgx_growth_bp(int64_t from_cents, int64_t to_cents, int64_t *out_bp)` | pure helper, no I/O | `OK`, `RANGE` (from is 0), `OVERFLOW` |

### 4.2 Structs (all fields are fixed-size integers, no implicit padding)

| Struct | Size | int64 fields | int32 fields |
|---|---|---|---|
| `lgx_month` | 72 | `debit_cents` `credit_cents` `balance_cents` `cumulative_cents` `moving_avg_cents` `growth_bp` | `year` `month` `entries` `window_used` `growth_valid` `pad` |
| `lgx_year` | 64 | `debit_cents` `credit_cents` `balance_cents` `cumulative_cents` `avg_monthly_cents` `growth_bp` | `year` `months` `entries` `growth_valid` |
| `lgx_summary` | 88 | `debit_cents` `credit_cents` `balance_cents` `avg_monthly_cents` `best_cents` `worst_cents` | `best_year` `best_month` `worst_year` `worst_month` `months` `active_months` `lines_read` `lines_accepted` `lines_rejected` `pad` |
| `lgx_projection` | 24 | `balance_cents` `cumulative_cents` | `year` `month` |

Field order in memory is: all the int64 fields first, then the int32 ones, in the order listed. The sizes are asserted in the header (`static_assert`); a binding should assert them too and refuse a library that disagrees.

### 4.3 Status codes

`0..4` and `-1..-8` come from the bridge and are passed through; `-20..-22` are new.

| Code | Name | Meaning |
|---|---|---|
| 0 | `LGX_OK` | success |
| 1 | `LGX_ERR_COBOL_INPUT` | `cobol_app` cannot open the input CSV |
| 2 | `LGX_ERR_COBOL_OUTPUT` | `cobol_app` cannot write the `.dat` |
| 3 | `LGX_WARN_REJECTED` | **warning, not an error**: done, some CSV lines were rejected, data is valid |
| 4 | `LGX_ERR_COBOL_OVERFLOW` | amount overflow, run aborted |
| -1 | `LGX_ERR_NOT_FOUND` | `cobol_app` not found |
| -2 | `LGX_ERR_SPAWN` | cannot start `cobol_app` |
| -3 | `LGX_ERR_SIGNAL` | `cobol_app` killed by a signal |
| -4 | `LGX_ERR_DATA` | `.dat` missing, corrupt, or failing the integrity checks |
| -5 | `LGX_ERR_ARG` | bad argument (null pointer...) |
| -6 | `LGX_ERR_CAPACITY` | output array too small; `*count` holds the **required** length |
| -7 | `LGX_ERR_HOME` | cannot determine the legacy tree |
| -8 | `LGX_ERR_UNEXPECTED` | unexpected failure |
| -20 | `LGX_ERR_NO_DATA` | the ledger has no monthly records |
| -21 | `LGX_ERR_OVERFLOW` | a calculation would overflow int64 |
| -22 | `LGX_ERR_RANGE` | argument outside its documented range |

> **Only 0 and 3 are success** for `lgx_refresh`. Treating "any non-negative" as success is the most common mistake: 1, 2 and 4 are positive and are errors.

### 4.4 Conventions every binding must respect

- **Money is integer cents, growth is integer basis points** (1 bp = 0.01%). Never convert to floating point to compute; only to *display*, and prefer exact decimals (`Decimal`, integer division) even then. Rounding is **half away from zero**.
- **Sizing protocol** for the three array functions: call with `out = NULL, max = 0`. The reply is `LGX_ERR_CAPACITY` (or `OK` for an empty array) and `*count` is the required length; allocate and call again. If the second call says `CAPACITY` again the data changed in between: start over (all bindings retry up to 3 times).
- **Refresh once, query many.** `lgx_refresh` spawns a process and rewrites the `.dat`. The queries only read the `.dat` (cheap, stateless, no global state). Do not query while a refresh is running.
- **Undefined growth**: `growth_valid == 0` means `growth_bp` is meaningless (first period, or a zero base). Expose it as `nil`/`None`/`Option`, never as `0`.
- **Where the library finds the tree**: `$LEGACY_HOME`, else relative to `lib_c_api.so` (see 3.2). A binding finds *its own* library by (1) an explicit path argument, (2) `$LEGACY_EXTENDER_LIB`, (3) `$LEGACY_HOME/lib/`, (4) its   position in the source tree. An explicit choice (1, 2) is **exclusive**: if it is wrong, fail loudly, never fall back silently.

### 4.5 What the calculations mean

| Item | Definition |
|---|---|
| Calendar series | from the first to the last month with entries; a month without entries has `entries = 0`, zero debit/credit/balance and the running balance carried over |
| Moving average | mean of the monthly balances of the last `window` months, rounded; `window_used < window` at the start of the series |
| Growth (month) | running balance versus the previous month's, in bp; undefined when the previous is 0 |
| Growth (year) | yearly balance versus the previous year's, in bp |
| `avg_monthly_cents` | balance divided by the calendar months in the period (gaps count) |
| Projection | the average monthly balance of the last `basis_months` months (or all, if fewer) carried flat for `horizon` months; a trend line for charts, **not** a forecast |
| Integrity checks | `M` records chronological; each running balance equals the previous plus the month's; sums equal the trailer; each `Y` record equals the aggregation of its months. Any failure is `LGX_ERR_DATA` |

---

## 5. Portability: why the tree can be moved

Copy `bin/`, `lib/` and `data/` anywhere and run `bin/extender_test` with an empty environment. This works because of **relative run-time search paths**:

| Binary | Finds its libraries through |
|---|---|
| `bin/cobol_app`, `bin/*_test` | `$ORIGIN/../lib` |
| `lib/lib_cpp_api.so` | `$ORIGIN` (so it finds `lib_c_api.so`) |
| `bin/dist/lua/lua_extender_core.so` | `$ORIGIN/../../lib` |

Three rules that took a bug each to learn:

1. **The `RUNPATH` of an executable does not apply to the dependencies of its libraries.** Every library that has dependencies needs its own `$ORIGIN` entry. `cobol_app` uses `DT_RPATH` (`--disable-new-dtags`) because libgmp is a dependency of libcob, not of the executable.
2. **`cobol/builder.pl` bundles `libcob` and its dependencies into `lib/`** and records what it copied in `lib/.cobol-bundled`, so the next build or `clean` removes exactly those files. A stale library in `lib/` would shadow the right one (`DT_RPATH` beats `LD_LIBRARY_PATH`).
3. **A build must never leave an absolute path of the build machine** in a binary. `setup.pl run` scrubs `LD_LIBRARY_PATH` and friends and checks with `ldd` that every non-libc library resolves inside `lib/`.

**Not portable, by design**: the Python venv (`bindings/python/.venv`, absolute paths inside; regenerate it with the builder) and anything you build outside `bin/lib/data`.

---

## 6. The builder contract (`builder.pl`)

Every component has its own `builder.pl` and it can be used alone:

```bash
perl cobol/builder.pl            # = all: build, then test
perl bridge/builder.pl build     # compile only
perl extender/builder.pl test    # run its tests (must be built)
perl bindings/lua/builder.pl clean
```

| Contract | |
|---|---|
| Modes | `all` (default) · `build` · `test` · `clean` |
| Exit status | `0` ok · `1` failure (message on stderr) · `2` usage error |
| Tests | always run **from `legacy/bin`**, like any user would |
| Writes | only `bin/`, `lib/` (and the component's own folder for a venv); `clean` removes only what that builder made, never data |

### 6.1 Safe by construction

- **No root.** Refuses to run as root (files would be owned by root and a normal user could not rebuild). `LEGACY_ALLOW_ROOT=1` overrides, with a warning. Nothing in a builder ever calls `sudo`.
- **No shell.** Every command is run in list form. Command names that come from the environment (`CC`, `CXX`, `COBC`, `PYTHON`, `LUA`) must be plain characters (`valid_command`), and an environment value is never interpolated into a string.
- **Same inputs, same build.** `CFLAGS`, `CXXFLAGS`, `LDFLAGS`, `LD_LIBRARY_PATH`, `LD_PRELOAD`... are discarded (`scrub_environment`). Component-specific ones are discarded in that component (`PYTHONPATH`, `LUA_INIT`...).
- **Out-of-tree CMake builds** in a private temporary directory, removed afterwards.

### 6.2 The template (every builder has the same shape)

```
POD                 NAME, SYNOPSIS, DESCRIPTION, modes, ENVIRONMENT, EXIT STATUS
use ...             the same module list in every builder
sub main            ON TOP: reads like a table of contents
modes               do_clean, do_build, do_test
component specifics build_context, check_prerequisites, find_toolchain + helpers
shared block        identical in every builder (between two marker lines)
exit main(@ARGV) unless caller;
```

`main` is identical everywhere:

```perl
sub main {
    my $mode = parse_args(@_);
    require_unprivileged();
    scrub_environment();

    my $ctx = build_context();
    return do_clean($ctx) if $mode eq 'clean';

    check_prerequisites( $ctx, $mode );
    find_toolchain($ctx) if $mode ne 'test';
    do_build($ctx)       if $mode ne 'test';
    do_test($ctx)        if $mode ne 'build';
    return 0;
}
```

`parse_args` function, may vary depending on the specific requirements of the language binding:

```perl
sub parse_args {
    my @args = @_;
    my $mode = @args ? shift @args : 'all';
    # In this case, the Python binding includes a usage example with a UI.
    return $mode if $mode =~ /^(?:all|build|test|clean|example)$/ && !@args;
    print STDERR "usage: builder.pl [all|build|test|clean|example]\n";
    exit 2;
}
```

The **shared block** sits between `# BEGIN shared-builder-helpers` and `# END shared-builder-helpers` and is byte-identical in every builder (the price of builders that work alone). `perl dev/setup.pl check` compares them and **fails** if one drifted. Its functions: `fail`, `run`, `capture`, `require_unprivileged`, `scrub_environment`, `valid_command`, `find_in_path`, `compiler_major`, `pick_compiler`, `ensure_writable_dirs`, `require_artifact`, `cmake_build`, `run_test_binary`. **Change the block in one builder, then copy it to all the others.** Everything outside the block is yours to change.

### 6.3 The existing builders

| Builder | Produces | Needs | Reads from the environment |
|---|---|---|---|
| `cobol/` | `bin/cobol_app`; `libcob`, `libgmp` (and what they need) copied to `lib/` | a GnuCOBOL 3.1/3.2 | `COBC`, `COBOL_HOME`, `COB_CC` |
| `bridge/` | `lib/lib_c_api.so`, `bin/c_api_test` | `bin/cobol_app`, CMake ≥ 3.16, GCC ≥ 14 | `CC` |
| `extender/` | `lib/lib_cpp_api.so`, `bin/extender_test` | `lib_c_api.so`, CMake ≥ 3.25, g++ ≥ 14 | `CXX` |
| `bindings/python/` | `bindings/python/.venv` (PySide6 inside) | Python ≥ 3.10 with `venv`; the extender to *test* | `PYTHON`, `LEGACY_NO_QT=1` |
| `bindings/lua/` | `bin/dist/lua/` (module, API, tests) | the extender, Lua 5.4 headers, CMake ≥ 3.25, GCC ≥ 14; `lua5.4` to *test* | `CC`, `LUA` |

---

## 7. The manifest (`Components.pm`)

`dev/LegacyDev/Components.pm` is the **only** place that knows which components exist. `Check` and `Pipeline` are generic: they loop over this list. Adding a component means adding one entry; neither module needs editing (unless it needs a tool nobody checks yet, section 9.5).

| Field | Meaning |
|---|---|
| `name`, `title` | short id; section title in the `check` report |
| `builder` | path of its `builder.pl`, relative to `legacy/` |
| `depends` | components built first. The build order is derived from it; unknown dependencies and cycles are rejected |
| `tools` | what it needs (below) |
| `requires` | source and data files that must exist |
| `artifacts` | what its builder produces: `{ path, label }`, or `{ globs => [...], label, missing }` for a set of files |
| `run` | what `setup.pl run` starts (below) |
| `env` | a sub `($ctx)` returning the environment variables its builder reads: this is how the toolchain `check` found reaches the builder |

**Tool kinds** (each is checked by a `check_*` function in `Check.pm`):

| Key | Value | Checked by |
|---|---|---|
| `cobol` | `1` | `check_cobol`: which GnuCOBOL, where from, what its libcob would drag into `lib/`, which C compiler it calls |
| `cc` / `cxx` | `{ min, label, option, apt }` | `check_compiler`: a GCC / g++ of at least `min`; `option` is the explicit command-line choice |
| `cmake` | `'3.25'` | `check_build_tools`: the **highest** version any component asks for |
| `python` | `{ min, label, option, apt }` | `check_python`: version and the `venv` module |
| `lua` | `{ version, label, option, apt }` | `check_lua`: interpreter of exactly that version, and its headers |

**Run entries** (`ok` = exit codes that pass, `warn` = `{ code => why }`):

| Form | When | What happens |
|---|---|---|
| `{ exe => 'cobol_app', ... }` | a native executable in `bin/` | `ldd` check that its libraries resolve inside `lib/`, then run from `bin/` with a clean environment |
| `{ name => 'lua_tests', via => 'builder-test' }` | no native executable (Python, Lua) | runs that builder's own `test` mode, from `bin/` |

A real entry (the Lua one, abridged):

```perl
{
    name      => 'lua',
    title     => 'Lua bindings',
    builder   => 'bindings/lua/builder.pl',
    depends   => ['extender'],
    tools     => {
        cc    => { min => 14, label => 'lua compiler', option => 'cc', apt => 'gcc-14' },
        cmake => '3.25',
        lua   => { version => '5.4', label => 'lua', option => 'lua', apt => 'lua5.4 liblua5.4-dev' },
    },
    requires  => [ 'bindings/lua/builder.pl', 'bindings/lua/CMakeLists.txt', ... ],
    artifacts => [ { path => 'bin/dist/lua/lua_extender_core.so', label => 'lua module' }, ... ],
    run       => [ { name => 'lua_tests', via => 'builder-test', ok => [0], warn => {} } ],
    env       => sub { my %e; $e{CC} = $_[0]{cc} if defined $_[0]{cc}; $e{LUA} = $_[0]{lua} if defined $_[0]{lua}; \%e },
},
```

---

## 8. The rest of `dev/`

| File | Role |
|---|---|
| `setup.pl` | Thin command line: `check`, `prepare`, `build`, `run [NAME...]`, `clean`, `all`, `help` (default). It parses options and dispatches; the work is in `LegacyDev::*` |
| `LegacyDev/Check.pm` | Read-only. One line per finding: `OK`, `WARN`, `FAIL` (exit 1). **Deviations** from the project design (a system `cobc`, GnuCOBOL 4.x, another GCC for the generated C, a libcob that drags 40 MB of libraries) are warnings that say *why*, measured when possible; `--strict` makes them failures. Also compares the builders' shared block |
| `LegacyDev/Pipeline.pm` | `build`, `run`, `clean`, `prepare`, `all`, driven by the manifest. Calls each builder through the contract; refuses to run as root unless `--allow-root` |
| `LegacyDev.pm` | Shared helpers: messages, list-form `run`/`capture`, `child_perl`, privilege handling (`root` → `sudo` → `su` → print the commands), `apt_ensure`, confirmation prompts |
| `prepare_legacy_env.pl` | Machine level: platform, apt packages (`gcc-13`, `gcc-14`, `g++-14`, `cmake`, `python3`, `python3-venv`, `lua5.4`, `liblua5.4-dev`), compilers, then GnuCOBOL. Exit `3` means *a privileged step is pending: its commands were printed* |
| `gnucobol_install.pl` | Builds GnuCOBOL from source into `/opt/gnucobol-V` (GPG-verified, minimal: libcob needs only libgmp and libc). Commands `install`, `verify`, `status`, `uninstall`. Build as a normal user; root only to hand over the prefix, once, up front |

`setup.pl` options worth knowing (`-h` or `--help` or `help` has all):

| Option | Effect |
|---|---|
| `--cobol-home DIR` / `--system-cobol` / `--gnucobol-version V` | choose the GnuCOBOL (explicit choices are exclusive: no silent fallback) |
| `--cc`, `--extender-cxx`, `--cobol-cc`, `--python`, `--lua` | choose a tool; same rule |
| `--strict` | deviations become failures (CI) |
| `--prepare` | in `all`: install what is missing instead of stopping |
| `--priv auto\|sudo\|su\|print` | how `prepare` gets root |
| `--allow-root` | build and run even as root (e.g. a throw-away container) |

Environment variables the project reads:

| Variable | Used by | Meaning |
|---|---|---|
| `COBOL_HOME`, `COBC`, `COB_CC` | `cobol/builder.pl` | which GnuCOBOL, which C compiler it calls |
| `CC`, `CXX` | bridge and Lua / extender builders | compiler (GCC ≥ 14) |
| `PYTHON`, `LUA` | Python / Lua builders | interpreter |
| `LEGACY_HOME` | bridge, extender, bindings | use another tree (tests use a copy) |
| `LEGACY_EXTENDER_LIB` | bindings | explicit path of `lib_cpp_api.so` |
| `LEGACY_NO_QT=1` | Python builder | do not download PySide6 |
| `LEGACY_ALLOW_ROOT=1` | every builder | allow running as root |

---

## 9. Trying another language

The extender is a C ABI, so **most languages can call it with no help from this repository**. What this section gives you is the path to make your experiment a first-class component: built, tested and reported by `setup.pl` like the others.

### 9.1 Choose the shape

| Shape | Languages (examples) | What you build | Model to copy |
|---|---|---|---|
| **A. Dynamic FFI**: the language loads `lib_cpp_api.so` at run time | Python (ctypes), Node (koffi), Julia (`ccall`), Java 22+ (Foreign Function & Memory), .NET (P/Invoke), Ruby (Fiddle), Rust or Go (via `libloading` / cgo) | pure source in the language; maybe a venv, `node_modules`, a `target/` | `bindings/python/` |
| **B. Native module**: compiled against the language's C API | Lua, a Python C extension, Node-API, PHP, Perl XS | a module (`.so`) that links `lib_cpp_api.so` | `bindings/lua/` |

Prefer **A** to start: no compiler, no headers, and you only use the contract.
Choose **B** when the language has no usable FFI, or you want its idiomatic types.

### 9.2 The checklist (what a binding must do)

A binding is "done" when it has parity with the existing ones:

1. **Finds the library** with the four-step order in 4.4 (explicit, `$LEGACY_EXTENDER_LIB`, `$LEGACY_HOME/lib`, source tree) and fails with a message that lists where it looked.
2. **Checks the ABI**: `lgx_version()` major.minor equals the one it was written for, and the struct sizes are 72 / 64 / 88 / 24.
3. **Declares the nine functions** with exact argument types (`int32_t`, `int64_t`, `size_t`; the arrays are pointers to the structs of 4.2).
4. **Implements the sizing protocol** with a retry (4.4).
5. **Maps status to errors**: 0 and 3 are success for `refresh`; anything else raises whatever the language raises. Keep the numeric status and the COBOL log on the error.
6. **Never uses floats for money.** Cents in, cents out; formatting with integer or exact-decimal arithmetic. Undefined growth is the language's "nothing".
7. **Has tests** that run **from `legacy/bin`** and exit non-zero on failure: invariants that hold for any data (running balance equals the sum of balances; balance equals debit minus credit; months have no holes) and, optionally, the sample numbers. Scenario tests (missing CSV, rejected lines, gaps) use a **copy** of the tree selected with `LEGACY_HOME`; they never touch the real data.
8. **Is documented** in its builder's POD and in a row of the tables in section 6.3.

### 9.3 Step by step

**Step 1. Create the folder**: `bindings/<lang>/` with `src/`, `tests/` and `builder.pl`.
Everything a binding produces lives in `bin/dist/<lang>/` (native modules, scripts) or inside its own folder (a venv, a build cache). It does **not** go into `lib/`, which is shared.

**Step 2. Write the binding** following 9.2. The Python binding is about 620 lines (plus an optional 300-line Qt adapter); the Lua one, about 260. Look at `bindings/python/src/legacy_ledger/_abi.py` for the shape of "load, declare, check".

**Step 3. Write the builder.** Copy the closest one (`bindings/lua/builder.pl` for a native module, `bindings/python/builder.pl` for a pure binding with a private environment). **Do not touch `main` or the shared block.** Edit only the component section:

| Function | You decide |
|---|---|
| `build_context` | the paths (`root`, `here`, where outputs go) |
| `check_prerequisites($ctx, $mode)` | what must exist first (`require_artifact`): the extender library to build or test, `bin/cobol_app` to test |
| `find_toolchain($ctx)` | find and validate your tools (compiler, interpreter, version) |
| `do_build` | produce the artifacts (`cmake_build` for a native module; create an environment and install dependencies otherwise) |
| `do_test` | `chdir` to `bin`, scrub the language's environment, run the tests with `run(...)` |
| `do_clean` | remove **only** what this builder made |

Rules: tools come from `$ENV{...}` through `valid_command`; commands run in list form; the test runs from `bin/`; use the language's isolation mechanism (a venv, a local `node_modules`, a `target/` dir) instead of installing system-wide.

**Step 4. Add the manifest entry** (section 7). `depends => ['extender']`; copy `tools` shape from a similar entry; `run` is `{ name => '<lang>_tests', via => 'builder-test' }`; `env` hands your builder the tools `check` found.

**Step 5. Teach `check` about the tool** (only if it is a new kind). In `Check.pm`: write `check_<tool>($ctx, $spec, $opt)` (model: `check_python`, `check_lua`): find the tool, validate the version, `report( ok|fail => $spec->{label}, ... )`, store the result in `$ctx`; add one dispatch line next to the others in `run_checks`; add the option to `setup.pl` (`GetOptionsFromArray` list and `--help` text). An explicit
`--<tool>` option must be **exclusive**.

**Step 6. (optional) `prepare`.** Add the apt packages to `@NATIVE_PKGS` in `prepare_legacy_env.pl` and a small `<tool>_version` check next to `python_version`.

**Step 7. Verify.**

```bash
perl dev/setup.pl check                    # your tool, files, "builder helpers identical in N builders"
perl bindings/<lang>/builder.pl            # build + test, alone
perl dev/setup.pl run <lang>_tests         # through the pipeline
perl dev/setup.pl                          # the whole thing
```

### 9.4 Ideas by language (untested here: starting points, not recipes)

| Language | Approach | Watch for |
|---|---|---|
| Rust | shape A: `libloading`, or `#[link(name = "_legacy_extender")]`; `#[repr(C)]` structs with the sizes above | an `$ORIGIN`-relative rpath if you link instead of loading (`-C link-arg=-Wl,-rpath,$ORIGIN/../lib`) |
| Go | shape A with cgo, or `purego` | cgo needs a C compiler; set the rpath through `#cgo LDFLAGS` |
| Node | shape A: `koffi` (no compile step) | struct arrays: allocate a `Buffer` of `count * size` |
| Julia | shape A: `ccall`, `@ccall`; `struct`s with the same field order | `Int32`/`Int64` exactly, not `Int` |
| Java | shape A: Foreign Function & Memory API (Java 22+) | `MemoryLayout.structLayout` must match the sizes |
| C# / .NET | shape A: P/Invoke with `[StructLayout(LayoutKind.Sequential)]` | `NativeLibrary.SetDllImportResolver` to apply the discovery order |
| Python C extension, Node-API, PHP, Perl XS | shape B | link only `lib_cpp_api.so`; never bundle another copy of the language runtime |

### 9.5 Not sure it is the right place? Ask the manifest

- *"Where do I put the binary?"* `bin/dist/<lang>/` or your own folder, never `lib/`.
- *"The tests need the COBOL program."* They run it themselves (through `lgx_refresh`). Your builder only has to `require_artifact` that `bin/cobol_app` exists.
- *"I need a tool `check` does not know."* Section 9.3, step 5.
- *"I changed the shared block."* Copy it to every builder; `check` tells you which differ.

---

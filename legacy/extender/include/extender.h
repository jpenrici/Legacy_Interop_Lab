// legacy/extender/include/extender.h

/*
 * legacy_extender.h - C ABI of the legacy extender (lib/lib_cpp_api.so)
 *
 * This is the contract for bindings (Python ctypes, Rust, Node, ...): plain C,
 * flat structs of fixed-size integers, no C++ types, no exceptions, no global
 * state. It adds to the ledger what COBOL and the C bridge do not provide:
 *
 *   - a CALENDAR series: months without entries are filled in (entries = 0),
 *     so averages and growth are not skewed by missing months
 *   - moving average and month-over-month growth
 *   - yearly report with year-over-year growth
 *   - summary (totals, average, best and worst month)
 *   - a simple projection of the running balance
 *
 * Money is integer CENTS in USD, never floating point. Growth is in BASIS
 * POINTS (1 bp = 0.01%), rounded half away from zero.
 *
 * Typical use (a UI):
 *     lgx_refresh(...)           run the COBOL ledger once (spawns a process)
 *     lgx_monthly_series(...)    then query as often as needed: the queries
 *     lgx_yearly_report(...)     only parse the .dat (cheap, no process)
 *     lgx_ledger_summary(...)
 *     lgx_project(...)
 *
 * Output arrays: pass out = NULL, max = 0 to learn the size. When max is too
 * small the call returns LGX_ERR_CAPACITY and *count holds the REQUIRED length.
 * The tree (<home>/bin/cobol_app, <home>/data/...) is found at run time from
 * the location of lib_c_api.so, exactly as in the C bridge; $LEGACY_HOME
 * overrides it.
 *
 * Every function is thread-safe with respect to the library itself, but they
 * all read the same .dat: do not query while lgx_refresh is running.
 */
#ifndef LEGACY_EXTENDER_H
#define LEGACY_EXTENDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LGX_API __attribute__((visibility("default")))

#define LGX_VERSION "0.1.0"
#define LGX_MAX_WINDOW 120 /*  moving-average window, in months          */
#define LGX_MAX_BASIS 120 /*   projection basis, in months               */
#define LGX_MAX_HORIZON 120 /* projection horizon, in months             */

/*
 * Status codes. 0..4 and -1..-8 are the codes of the C bridge, passed through;
 * the -2x codes are new. A 'warning' (3) is not an error: data is valid.
 */
enum lgx_status {
    LGX_OK = 0,
    LGX_ERR_COBOL_INPUT = 1, /*    cobol_app: cannot open the input CSV   */
    LGX_ERR_COBOL_OUTPUT = 2, /*   cobol_app: cannot write the .dat       */
    LGX_WARN_REJECTED = 3, /*      done, some CSV lines were rejected      */
    LGX_ERR_COBOL_OVERFLOW = 4, /* cobol_app: amount overflow, aborted    */
    LGX_ERR_NOT_FOUND = -1, /*     cobol_app not found                    */
    LGX_ERR_SPAWN = -2, /*         cannot start cobol_app                 */
    LGX_ERR_SIGNAL = -3, /*        cobol_app killed by a signal           */
    LGX_ERR_DATA = -4, /*          .dat missing, corrupt or inconsistent   */
    LGX_ERR_ARG = -5, /*           bad argument                            */
    LGX_ERR_CAPACITY = -6, /*      output array too small (*count = needed)*/
    LGX_ERR_HOME = -7, /*          cannot determine <home>                 */
    LGX_ERR_UNEXPECTED = -8, /*    unexpected failure                      */
    LGX_ERR_NO_DATA = -20, /*      the ledger has no monthly records       */
    LGX_ERR_OVERFLOW = -21, /*     calculation would overflow int64        */
    LGX_ERR_RANGE = -22 /*         argument outside its documented range   */
};

/* One calendar month. 72 bytes. */
typedef struct lgx_month {
    int64_t debit_cents;
    int64_t credit_cents;
    int64_t balance_cents; /*    debit - credit of the month                 */
    int64_t cumulative_cents; /* running balance at the end of the month     */
    int64_t moving_avg_cents; /* average monthly balance over window_used    */
    int64_t growth_bp; /*        cumulative balance vs the previous month    */
    int32_t year;
    int32_t month; /*            1..12                                       */
    int32_t entries; /*          accepted CSV lines; 0 = month filled in     */
    int32_t window_used; /*      months in the moving average (<= window)    */
    int32_t growth_valid; /*     0 when there is no previous month or it is 0*/
    int32_t pad; /*              always 0                                    */
} lgx_month;

/* One calendar year. 64 bytes. */
typedef struct lgx_year {
    int64_t debit_cents;
    int64_t credit_cents;
    int64_t balance_cents; /*     debit - credit of the year             */
    int64_t cumulative_cents; /*  running balance at year end            */
    int64_t avg_monthly_cents; /* balance / months                       */
    int64_t growth_bp; /*         balance vs the previous year           */
    int32_t year;
    int32_t months; /*            calendar months of the series in year  */
    int32_t entries;
    int32_t growth_valid;
} lgx_year;

/* Whole-ledger summary. 88 bytes. */
typedef struct lgx_summary {
    int64_t debit_cents;
    int64_t credit_cents;
    int64_t balance_cents; /*        final running balance                  */
    int64_t avg_monthly_cents; /*    balance / months of the calendar series*/
    int64_t best_cents; /*           highest monthly balance                */
    int64_t worst_cents; /*          lowest monthly balance                 */
    int32_t best_year, best_month;
    int32_t worst_year, worst_month;
    int32_t months; /*               calendar months in the series          */
    int32_t active_months; /*        months with entries                    */
    int32_t lines_read, lines_accepted, lines_rejected;
    int32_t pad;
} lgx_summary;

/* One projected month. 24 bytes. */
typedef struct lgx_projection {
    int64_t balance_cents; /*    projected monthly balance              */
    int64_t cumulative_cents; /* projected running balance              */
    int32_t year;
    int32_t month;
} lgx_projection;

#ifdef __cplusplus
static_assert(sizeof(lgx_month) == 72, "lgx_month ABI");
static_assert(sizeof(lgx_year) == 64, "lgx_year ABI");
static_assert(sizeof(lgx_summary) == 88, "lgx_summary ABI");
static_assert(sizeof(lgx_projection) == 24, "lgx_projection ABI");
#else
_Static_assert(sizeof(lgx_month) == 72, "lgx_month ABI"); // C assert
_Static_assert(sizeof(lgx_year) == 64, "lgx_year ABI");
_Static_assert(sizeof(lgx_summary) == 88, "lgx_summary ABI");
_Static_assert(sizeof(lgx_projection) == 24, "lgx_projection ABI");
#endif

/* Library version ("0.1.0") and text for any status code (never NULL). */
LGX_API const char* lgx_version(void);
LGX_API const char* lgx_strerror(int status);

/* Resolved <home> directory. */
LGX_API int lgx_home(char* buf, size_t size);

/*
 * Runs the COBOL ledger (cobol_app) and waits for it. log (optional) gets its
 * output. Returns LGX_OK, LGX_WARN_REJECTED (data valid) or an error; unlike
 * the raw bridge, exit codes 1, 2 and 4 are errors.
 */
LGX_API int lgx_refresh(char* log, size_t log_size);

/*
 * Calendar series from the first to the last month with entries.
 * window: moving-average length, 1..LGX_MAX_WINDOW.
 */
LGX_API int lgx_monthly_series(int32_t window, lgx_month* out, size_t max,
    size_t* count);

/* One entry per calendar year of the series. */
LGX_API int lgx_yearly_report(lgx_year* out, size_t max, size_t* count);

LGX_API int lgx_ledger_summary(lgx_summary* out);

/*
 * Projects the running balance: the average monthly balance of the last
 * basis_months months (1..LGX_MAX_BASIS, or all of them when fewer exist) is
 * carried flat for horizon months (1..LGX_MAX_HORIZON). A naive trend line for
 * charts, not a forecasting model.
 */
LGX_API int lgx_project(int32_t basis_months, int32_t horizon,
    lgx_projection* out, size_t max, size_t* count);

/*
 * Pure helper, no I/O: (to - from) / |from| in basis points, rounded half
 * away from zero. from == 0 gives LGX_ERR_RANGE; overflow LGX_ERR_OVERFLOW.
 */
LGX_API int lgx_growth_bp(int64_t from_cents, int64_t to_cents, int64_t* out_bp);

#ifdef __cplusplus
}
#endif

#endif /* LEGACY_EXTENDER_H */

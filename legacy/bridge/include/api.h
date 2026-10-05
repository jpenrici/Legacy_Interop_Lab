/*
 * api.h - C bridge to the COBOL ledger (legacy_app)
 *
 * Plain C ABI, flat structs, fixed-size types: easy to call through FFI
 * (Python ctypes, Node ffi, Rust extern "C", ...).
 *
 * The library finds its tree at run time (relocatable):
 *     <home>/bin/legacy_app            run with <home>/bin as cwd
 *     <home>/data/store/cobol/cb_data.dat
 * <home> = $LEGACY_HOME if set, else two levels above this library
 * (<home>/lib/lib_c_api.so).
 *
 * All money values are integer CENTS in USD (no floating point).
 */
#ifndef LEGACY_API_H
#define LEGACY_API_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LG_API __attribute__((visibility("default")))

/* Status codes: 0..4 mirror the legacy_app exit code, negatives are ours. */
enum lg_status {
    LG_OK = 0, /*                 all lines accepted                       */
    LG_ERR_COBOL_INPUT = 1, /*    legacy_app: cannot open the CSV          */
    LG_ERR_COBOL_OUTPUT = 2, /*   legacy_app: cannot write the .dat        */
    LG_WARN_REJECTED = 3, /*      done, but some CSV lines were rejected   */
    LG_ERR_COBOL_OVERFLOW = 4, /* legacy_app: amount overflow, aborted     */
    LG_ERR_NOT_FOUND = -1, /*     <home>/bin/legacy_app missing            */
    LG_ERR_SPAWN = -2, /*         fork/exec/wait failed                    */
    LG_ERR_SIGNAL = -3, /*        legacy_app killed by a signal            */
    LG_ERR_DATA = -4, /*          .dat missing, corrupt or incomplete      */
    LG_ERR_ARG = -5, /*           bad argument                             */
    LG_ERR_CAPACITY = -6, /*      output array too small                   */
    LG_ERR_HOME = -7, /*          cannot determine <home>                  */
    LG_ERR_UNEXPECTED = -8 /*     unknown exit code from legacy_app        */
};

/* One ledger line: kind 'M' = month, 'Y' = year closing (month = 0). */
typedef struct lg_record {
    int64_t debit_cents;
    int64_t credit_cents;
    int64_t balance_cents; /*    debit - credit of the period             */
    int64_t cumulative_cents; /* running balance at end of the period     */
    int32_t year;
    int32_t month;
    int32_t entries; /*          accepted CSV lines in the period         */
    char kind; /*                'M' or 'Y'                               */
    char pad[3]; /*              explicit padding, always zero            */
} lg_record; /*                  48 bytes on LP64                         */

/* Trailer of the .dat (record 'T'). */
typedef struct lg_summary {
    int64_t debit_cents;
    int64_t credit_cents;
    int64_t balance_cents;
    int32_t lines_read;
    int32_t lines_accepted;
    int32_t lines_rejected;
    int32_t pad;
} lg_summary; /* 40 bytes on LP64                         */

/* Library version, e.g. "1.0.0". */
LG_API const char* lg_version(void);

/* Text for a status code (never NULL). */
LG_API const char* lg_strerror(int status);

/* Writes the resolved <home> into buf. Returns LG_OK or LG_ERR_*. */
LG_API int lg_home(char* buf, size_t size);

/*
 * Runs legacy_app (cwd = <home>/bin) and waits for it.
 * log (optional) receives its stdout+stderr, truncated, NUL-terminated.
 * Returns the legacy_app exit code (0..4) or a negative LG_ERR_*.
 */
LG_API int lg_run(char* log, size_t log_size);

/*
 * Parses <home>/data/store/cobol/cb_data.dat into out[0..max-1].
 * *count receives the number of records stored (M and Y, file order).
 * Validates layout, trailer presence and entry-count consistency.
 * Returns LG_OK or a negative LG_ERR_*.
 */
LG_API int lg_load(lg_record* out, size_t max, size_t* count,
    lg_summary* summary);

/*
 * lg_run + lg_load. The .dat is only loaded when legacy_app finished
 * (LG_OK or LG_WARN_REJECTED); otherwise the old file may be stale.
 * Returns LG_OK, LG_WARN_REJECTED (data loaded), or an error code.
 */
LG_API int lg_process(lg_record* out, size_t max, size_t* count,
    lg_summary* summary, char* log, size_t log_size);

/* Formats cents as "-1234.56". Returns LG_OK or LG_ERR_ARG if too small. */
LG_API int lg_format_cents(int64_t cents, char* buf, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* LEGACY_API_H */

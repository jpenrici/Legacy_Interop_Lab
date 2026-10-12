#![allow(dead_code)]

use std::os::raw::{c_char, c_int, c_void};

pub const LGX_OK: c_int = 0;
pub const LGX_WARN_REJECTED: c_int = 3;
pub const LGX_ERR_CAPACITY: c_int = -6;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct LgxMonth {
    pub debit_cents: i64,
    pub credit_cents: i64,
    pub balance_cents: i64,
    pub cumulative_cents: i64,
    pub moving_avg_cents: i64,
    pub growth_bp: i64,
    pub year: i32,
    pub month: i32,
    pub entries: i32,
    pub window_used: i32,
    pub growth_valid: i32,
    pub pad: i32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct LgxSummary {
    pub debit_cents: i64,
    pub credit_cents: i64,
    pub balance_cents: i64,
    pub avg_monthly_cents: i64,
    pub best_cents: i64,
    pub worst_cents: i64,
    pub best_year: i32,
    pub best_month: i32,
    pub worst_year: i32,
    pub worst_month: i32,
    pub months: i32,
    pub active_months: i32,
    pub lines_read: i32,
    pub lines_accepted: i32,
    pub lines_rejected: i32,
    pub pad: i32,
}

extern "C" {
    pub fn lgx_version() -> *const c_char;
    pub fn lgx_strerror(status: c_int) -> *const c_char;
    pub fn lgx_home(buf: *mut c_char, size: usize) -> c_int;
    pub fn lgx_refresh(log: *mut c_char, log_size: usize) -> c_int;
    pub fn lgx_monthly_series(
        window: c_int,
        out: *mut LgxMonth,
        max: usize,
        count: *mut usize,
    ) -> c_int;
    pub fn lgx_ledger_summary(out: *mut LgxSummary) -> c_int;
}

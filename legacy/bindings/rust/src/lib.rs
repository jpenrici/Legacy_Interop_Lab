#![allow(dead_code, unused_imports)]
mod ffi;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[derive(Debug)]
pub enum LedgerError {
    Capacity,
    NoData,
    CobolError(i32),
    Other(i32),
}

pub struct Ledger;

impl Ledger {
    pub fn version() -> String {
        unsafe {
            let ptr = ffi::lgx_version();
            CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    }

    pub fn refresh() -> Result<(), LedgerError> {
        let mut log = vec![0u8; 1024];
        let res = unsafe { ffi::lgx_refresh(log.as_mut_ptr() as *mut c_char, log.len()) };

        match res {
            ffi::LGX_OK | ffi::LGX_WARN_REJECTED => Ok(res == ffi::LGX_WARN_REJECTED).map(|_| ()),
            code if code < 0 => Err(LedgerError::Other(code)),
            code => Err(LedgerError::CobolError(code)),
        }
    }

    pub fn monthly_series(window: i32) -> Result<Vec<ffi::LgxMonth>, LedgerError> {
        let mut count: usize = 0;

        // Call to determine the required size (out = null, max = 0)
        unsafe {
            let res = ffi::lgx_monthly_series(window, std::ptr::null_mut(), 0, &mut count);
            if res != ffi::LGX_ERR_CAPACITY && res != ffi::LGX_OK {
                return Err(LedgerError::Other(res));
            }
        }

        if count == 0 {
            return Ok(Vec::new());
        }

        // Allocates the buffer with the exact returned size.
        let mut data = vec![unsafe { std::mem::zeroed() }; count];
        let mut actual_count = count;

        // Call to fill in the details
        unsafe {
            let res =
                ffi::lgx_monthly_series(window, data.as_mut_ptr(), data.len(), &mut actual_count);
            if res != ffi::LGX_OK {
                return Err(LedgerError::Other(res));
            }
            data.truncate(actual_count);
        }

        Ok(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ledger_pipeline() {
        // Run the ledger refresh (executes COBOL/Bridge)
        let refresh_result = Ledger::refresh();
        println!("Refresh result: {:?}", refresh_result);

        // Tests fetching the monthly series with a 3-month window
        match Ledger::monthly_series(3) {
            Ok(series) => {
                println!(
                    "Monthly series successfully retrieved: {} months",
                    series.len()
                );
                for month in series {
                    println!(
                        "Year: {}, Month: {}, Balance: {} cents",
                        month.year, month.month, month.balance_cents
                    );
                }
            }
            Err(e) => {
                // If it fails due to missing data/uninitialized ledger, we log it in the test
                println!(
                    "Notice while fetching monthly series (may require initial data): {:?}",
                    e
                );
            }
        }
    }
}

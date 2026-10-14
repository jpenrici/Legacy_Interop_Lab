unit binding;

{$mode objfpc}{$H+}

interface

uses
    SysUtils, ctypes;

    {$IFNDEF LINUX}
        {$FATAL 'Error: This binding is restricted exclusively to Linux systems.'}
    {$ENDIF}

const
    LIB_NAME = 'lib_cpp_api.so';

    // Status codes from the C ABI
    LGX_OK = 0;
    LGX_WARN_REJECTED = 3;
    LGX_ERR_CAPACITY = -6;

type
    TLgxMonth = packed record
                           debit_cents: Int64;
                           credit_cents: Int64;
                           balance_cents: Int64;
                           cumulative_cents: Int64;
                           moving_avg_cents: Int64;
                           growth_bp: Int64;
                           year: Int32;
                           month: Int32;
                           entries: Int32;
                           window_used: Int32;
                           growth_valid: Int32;
                           pad: Int32;
                       end;
    PLgxMonth = ^TLgxMonth;

// Public wrapper functions exported by the unit
function GetVersion(): string;
function RefreshLedger(var LogMsg: string): cint;
function GetMonthlySeries(Window: cint; out Data: array of TLgxMonth; var Count: SizeUInt): cint;

implementation

// FFI External declarations matching extender.h
function lgx_version(): PChar; cdecl; external LIB_NAME;
function lgx_refresh(log: PChar; log_size: SizeUInt): cint; cdecl; external LIB_NAME;
function lgx_monthly_series(window: cint; out_buf: PLgxMonth; max: SizeUInt; count: PSizeUInt): cint; cdecl; external LIB_NAME;

function GetVersion(): string;
begin
    Result := StrPas(lgx_version());
end;

function RefreshLedger(var LogMsg: string): cint;
var
    LogBuffer: array[0..1023] of Char;
begin
    FillChar(LogBuffer, SizeOf(LogBuffer), 0);
    Result := lgx_refresh(@LogBuffer[0], SizeOf(LogBuffer));
    LogMsg := StrPas(LogBuffer);
end;

function GetMonthlySeries(Window: cint; out Data: array of TLgxMonth; var Count: SizeUInt): cint;
var
    Ptr: PLgxMonth;
begin
    if Length(Data) > 0 then
        Ptr := @Data[0]
    else
        Ptr := nil;

    Result := lgx_monthly_series(Window, Ptr, Length(Data), @Count);
end;

end.

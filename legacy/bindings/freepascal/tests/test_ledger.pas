program test_ledger;

{$mode objfpc}{$H+}

uses
    SysUtils, ctypes, binding;

var
    VersionStr: String;
    RefreshRes: cint;
    LogMsg: String;
    Count: SizeUInt;
    Res: cint;
    MonthlyData: array of TLgxMonth;
    I: Integer;

begin
    Writeln();
    Writeln('=== FreePascal Ledger Binding Test (Modular) ===');

    // 1. Version test
    VersionStr := GetVersion();
    Writeln('Library version: ', VersionStr);

    // 2. Refresh test
    RefreshRes := RefreshLedger(LogMsg);
    Writeln('Refresh result code: ', RefreshRes);

    if (RefreshRes <> LGX_OK) and (RefreshRes <> LGX_WARN_REJECTED) then
    begin
        Writeln(StdErr, 'Error: Ledger refresh failed. Details: ', LogMsg);
        Halt(1);
    end;

    // 3. Capacity protocol test for monthly series
    Count := 0;
    SetLength(MonthlyData, 0);
    Res := GetMonthlySeries(3, MonthlyData, Count);

    if (Res <> LGX_ERR_CAPACITY) and (Res <> LGX_OK) then
    begin
        Writeln(StdErr, 'Error: Failed to query monthly series size. Code: ', Res);
        Halt(1);
    end;

    Writeln('Required months count: ', Count);

    if Count > 0 then
    begin
        SetLength(MonthlyData, Count);
        Res := GetMonthlySeries(3, MonthlyData, Count);

        if Res = LGX_OK then
        begin
            Writeln();
            Writeln('--- Monthly Series Data ---');
            for I := 0 to Count - 1 do
            begin
                Writeln(Format('Year: %d, Month: %d, Balance: %d cents',
                               [MonthlyData[I].year, MonthlyData[I].month, MonthlyData[I].balance_cents]));
            end;
        end
        else
        begin
            Writeln(StdErr, 'Error: Failed to retrieve monthly data. Code: ', Res);
            Halt(1);
        end;
    end;

    Writeln();
    Writeln('Test completed successfully.');
end.

       IDENTIFICATION DIVISION.
       PROGRAM-ID. LEDGER.
      *----------------------------------------------------------------
      * LEDGER - MONTHLY GENERAL LEDGER WITH YEARLY CLOSING (USD)
      *
      * INPUT  : ../data/input/cobol/cb_data.csv   (LINE SEQUENTIAL)
      *          YYYY-MM-DD,ACCOUNT,D|C,AMOUNT,DESCRIPTION
      *          CHRONOLOGICAL ORDER, NO QUOTES, NO COMMAS IN TEXT.
      * OUTPUT : ../data/store/cobol/cb_data.dat   (LINE SEQUENTIAL)
      *          M = MONTH RECORD, Y = YEAR RECORD, T = TRAILER
      *          M/Y LAYOUT (74 BYTES):
      *            01 TYPE   02-05 YEAR   06-07 MONTH
      *            08-22 DEBIT  23-37 CREDIT  38-52 BALANCE
      *            53-67 CUMULATIVE  68-74 ENTRY COUNT
      *          T LAYOUT (67 BYTES):
      *            01 TYPE   02-08 READ  09-15 ACCEPTED  16-22 REJECTED
      *            23-37 DEBIT  38-52 CREDIT  53-67 BALANCE
      *          MONEY = -99999999999.99 (SIGN + 11 DIGITS + . + 2).
      * PATHS  : RELATIVE TO LEGACY/BIN. RUN THE PROGRAM FROM THERE.
      * RETURN : 0 OK              1 INPUT FILE ERROR
      *          2 OUTPUT ERROR    3 DONE, SOME LINES REJECTED
      *          4 AMOUNT OVERFLOW (RUN ABORTED)
      *----------------------------------------------------------------
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT IN-FILE ASSIGN TO WS-IN-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS WS-IN-STATUS.
           SELECT OUT-FILE ASSIGN TO WS-OUT-PATH
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS WS-OUT-STATUS.

       DATA DIVISION.
       FILE SECTION.
       FD  IN-FILE.
       01  IN-REC                    PIC X(120).
       FD  OUT-FILE.
       01  OUT-REC                   PIC X(80).

       WORKING-STORAGE SECTION.
       01  WS-IN-PATH                PIC X(60)
           VALUE "../data/input/cobol/cb_data.csv".
       01  WS-OUT-PATH               PIC X(60)
           VALUE "../data/store/cobol/cb_data.dat".
       01  WS-IN-STATUS              PIC XX.
       01  WS-OUT-STATUS             PIC XX.
       01  WS-SWITCHES.
           05  WS-EOF-SW             PIC X VALUE "N".
               88  END-OF-INPUT      VALUE "Y".
           05  WS-VALID-SW           PIC X VALUE "Y".
               88  LINE-OK           VALUE "Y".
           05  WS-ABORT-SW           PIC X VALUE "N".
               88  RUN-ABORTED       VALUE "Y".
           05  WS-FIRST-SW           PIC X VALUE "Y".
               88  FIRST-ENTRY       VALUE "Y".
       01  WS-COUNTERS.
           05  WS-READ-CNT           PIC 9(7) VALUE 0.
           05  WS-OK-CNT             PIC 9(7) VALUE 0.
           05  WS-REJ-CNT            PIC 9(7) VALUE 0.
       01  WS-REASON                 PIC X(30).
       01  WS-FIELD-CNT              PIC 9(2).
      * PARSED INPUT FIELDS
       01  WS-DATE-TXT.
           05  WS-D-YYYY             PIC X(4).
           05  WS-D-SEP1             PIC X.
           05  WS-D-MM               PIC X(2).
           05  WS-D-SEP2             PIC X.
           05  WS-D-DD               PIC X(2).
       01  WS-DATE-NUM.
           05  WS-N-YYYY             PIC 9(4).
           05  WS-N-MM               PIC 9(2).
           05  WS-N-DD               PIC 9(2).
       01  WS-DATE-9 REDEFINES WS-DATE-NUM PIC 9(8).
       01  WS-ACCOUNT                PIC X(12).
       01  WS-DC-TXT                 PIC X(4).
       01  WS-AMT-TXT                PIC X(20).
       01  WS-DESC-TXT               PIC X(60).
       01  WS-AMOUNT                 PIC S9(11)V99 VALUE 0.
      * CONTROL BREAK KEYS AND ACCUMULATORS
       01  WS-CUR-YEAR               PIC 9(4) VALUE 0.
       01  WS-CUR-MONTH              PIC 9(2) VALUE 0.
       01  WS-CUR-KEY                PIC 9(6) VALUE 0.
       01  WS-NEW-KEY                PIC 9(6) VALUE 0.
       01  WS-MONTH-ACC.
           05  WS-M-DEBIT            PIC S9(11)V99 VALUE 0.
           05  WS-M-CREDIT           PIC S9(11)V99 VALUE 0.
           05  WS-M-COUNT            PIC 9(7) VALUE 0.
       01  WS-YEAR-ACC.
           05  WS-Y-DEBIT            PIC S9(11)V99 VALUE 0.
           05  WS-Y-CREDIT           PIC S9(11)V99 VALUE 0.
           05  WS-Y-COUNT            PIC 9(7) VALUE 0.
       01  WS-TOTAL-ACC.
           05  WS-T-DEBIT            PIC S9(11)V99 VALUE 0.
           05  WS-T-CREDIT           PIC S9(11)V99 VALUE 0.
       01  WS-BALANCE                PIC S9(11)V99 VALUE 0.
       01  WS-CUMULATIVE             PIC S9(11)V99 VALUE 0.
      * OUTPUT RECORDS
       01  WS-DETAIL-REC.
           05  DR-TYPE               PIC X.
           05  DR-YEAR               PIC 9(4).
           05  DR-MONTH              PIC 9(2).
           05  DR-DEBIT              PIC -9(11).99.
           05  DR-CREDIT             PIC -9(11).99.
           05  DR-BALANCE            PIC -9(11).99.
           05  DR-CUMULATIVE         PIC -9(11).99.
           05  DR-COUNT              PIC 9(7).
       01  WS-TRAILER-REC.
           05  TR-TYPE               PIC X VALUE "T".
           05  TR-READ               PIC 9(7).
           05  TR-ACCEPTED           PIC 9(7).
           05  TR-REJECTED           PIC 9(7).
           05  TR-DEBIT              PIC -9(11).99.
           05  TR-CREDIT             PIC -9(11).99.
           05  TR-BALANCE            PIC -9(11).99.

       PROCEDURE DIVISION.
       0000-MAIN.
           PERFORM 1000-OPEN-FILES
           IF RETURN-CODE = 0
               PERFORM 2000-PROCESS-INPUT
                   UNTIL END-OF-INPUT OR RUN-ABORTED
               IF NOT RUN-ABORTED
                   PERFORM 3000-FINISH-RUN
               END-IF
               PERFORM 9000-CLOSE-FILES
           END-IF
           PERFORM 9100-SET-RETURN-CODE
           STOP RUN.

       1000-OPEN-FILES.
           OPEN INPUT IN-FILE
           IF WS-IN-STATUS NOT = "00"
               DISPLAY "LEDGER: CANNOT OPEN INPUT, STATUS "
                   WS-IN-STATUS UPON SYSERR
               MOVE 1 TO RETURN-CODE
           ELSE
               OPEN OUTPUT OUT-FILE
               IF WS-OUT-STATUS NOT = "00"
                   DISPLAY "LEDGER: CANNOT OPEN OUTPUT, STATUS "
                       WS-OUT-STATUS UPON SYSERR
                   CLOSE IN-FILE
                   MOVE 2 TO RETURN-CODE
               END-IF
           END-IF.

       2000-PROCESS-INPUT.
           READ IN-FILE
               AT END
                   SET END-OF-INPUT TO TRUE
               NOT AT END
                   ADD 1 TO WS-READ-CNT
                   PERFORM 2100-VALIDATE-LINE
                   IF LINE-OK
                       PERFORM 2200-POST-ENTRY
                   ELSE
                       PERFORM 2900-REJECT-LINE
                   END-IF
           END-READ.

       2100-VALIDATE-LINE.
           MOVE "Y" TO WS-VALID-SW
           MOVE SPACES TO WS-REASON
           PERFORM 2110-SPLIT-FIELDS
           IF LINE-OK
               PERFORM 2120-CHECK-DATE
           END-IF
           IF LINE-OK
               PERFORM 2130-CHECK-TYPE
           END-IF
           IF LINE-OK
               PERFORM 2140-CHECK-AMOUNT
           END-IF
           IF LINE-OK
               PERFORM 2150-CHECK-ORDER
           END-IF.

       2110-SPLIT-FIELDS.
           MOVE SPACES TO WS-DATE-TXT WS-ACCOUNT WS-DC-TXT
                          WS-AMT-TXT WS-DESC-TXT
           MOVE 0 TO WS-FIELD-CNT
           UNSTRING IN-REC DELIMITED BY ","
               INTO WS-DATE-TXT WS-ACCOUNT WS-DC-TXT
                    WS-AMT-TXT WS-DESC-TXT
               TALLYING IN WS-FIELD-CNT
               ON OVERFLOW
                   MOVE 4 TO WS-FIELD-CNT
           END-UNSTRING
           IF WS-FIELD-CNT < 4 OR WS-ACCOUNT = SPACES
               MOVE "N" TO WS-VALID-SW
               MOVE "BAD FIELD COUNT" TO WS-REASON
           END-IF.

       2120-CHECK-DATE.
           IF WS-D-SEP1 NOT = "-" OR WS-D-SEP2 NOT = "-"
              OR WS-D-YYYY NOT NUMERIC OR WS-D-MM NOT NUMERIC
              OR WS-D-DD NOT NUMERIC
               MOVE "N" TO WS-VALID-SW
               MOVE "BAD DATE FORMAT" TO WS-REASON
           ELSE
               MOVE WS-D-YYYY TO WS-N-YYYY
               MOVE WS-D-MM   TO WS-N-MM
               MOVE WS-D-DD   TO WS-N-DD
               IF FUNCTION TEST-DATE-YYYYMMDD(WS-DATE-9) NOT = 0
                   MOVE "N" TO WS-VALID-SW
                   MOVE "INVALID CALENDAR DATE" TO WS-REASON
               END-IF
           END-IF.

       2130-CHECK-TYPE.
           IF WS-DC-TXT NOT = "D" AND WS-DC-TXT NOT = "C"
               MOVE "N" TO WS-VALID-SW
               MOVE "TYPE MUST BE D OR C" TO WS-REASON
           END-IF.

       2140-CHECK-AMOUNT.
           IF FUNCTION TEST-NUMVAL(WS-AMT-TXT) NOT = 0
               MOVE "N" TO WS-VALID-SW
               MOVE "AMOUNT NOT NUMERIC" TO WS-REASON
           ELSE
               COMPUTE WS-AMOUNT = FUNCTION NUMVAL(WS-AMT-TXT)
                   ON SIZE ERROR
                       MOVE "N" TO WS-VALID-SW
                       MOVE "AMOUNT TOO LARGE" TO WS-REASON
               END-COMPUTE
               IF LINE-OK
                   IF WS-AMOUNT NOT > 0
                      OR WS-AMOUNT NOT = FUNCTION NUMVAL(WS-AMT-TXT)
                       MOVE "N" TO WS-VALID-SW
                       MOVE "AMOUNT MUST BE >0, 2 DECIMALS"
                           TO WS-REASON
                   END-IF
               END-IF
           END-IF.

       2150-CHECK-ORDER.
           COMPUTE WS-NEW-KEY = WS-N-YYYY * 100 + WS-N-MM
           IF NOT FIRST-ENTRY AND WS-NEW-KEY < WS-CUR-KEY
               MOVE "N" TO WS-VALID-SW
               MOVE "OUT OF CHRONOLOGICAL ORDER" TO WS-REASON
           END-IF.

       2200-POST-ENTRY.
           IF FIRST-ENTRY
               MOVE "N" TO WS-FIRST-SW
               MOVE WS-N-YYYY TO WS-CUR-YEAR
               MOVE WS-N-MM   TO WS-CUR-MONTH
               MOVE WS-NEW-KEY TO WS-CUR-KEY
           ELSE
               IF WS-NEW-KEY > WS-CUR-KEY
                   PERFORM 2300-CLOSE-MONTH
                   IF WS-N-YYYY NOT = WS-CUR-YEAR
                       PERFORM 2400-CLOSE-YEAR
                   END-IF
                   MOVE WS-N-YYYY TO WS-CUR-YEAR
                   MOVE WS-N-MM   TO WS-CUR-MONTH
                   MOVE WS-NEW-KEY TO WS-CUR-KEY
               END-IF
           END-IF
           IF NOT RUN-ABORTED
               PERFORM 2210-ACCUMULATE
           END-IF.

       2210-ACCUMULATE.
           ADD 1 TO WS-OK-CNT
           ADD 1 TO WS-M-COUNT
           IF WS-DC-TXT = "D"
               ADD WS-AMOUNT TO WS-M-DEBIT
                   ON SIZE ERROR PERFORM 9200-OVERFLOW
               END-ADD
           ELSE
               ADD WS-AMOUNT TO WS-M-CREDIT
                   ON SIZE ERROR PERFORM 9200-OVERFLOW
               END-ADD
           END-IF.

       2300-CLOSE-MONTH.
           COMPUTE WS-BALANCE = WS-M-DEBIT - WS-M-CREDIT
               ON SIZE ERROR PERFORM 9200-OVERFLOW
           END-COMPUTE
           ADD WS-BALANCE TO WS-CUMULATIVE
               ON SIZE ERROR PERFORM 9200-OVERFLOW
           END-ADD
           IF NOT RUN-ABORTED
               MOVE "M"           TO DR-TYPE
               MOVE WS-CUR-YEAR   TO DR-YEAR
               MOVE WS-CUR-MONTH  TO DR-MONTH
               MOVE WS-M-DEBIT    TO DR-DEBIT
               MOVE WS-M-CREDIT   TO DR-CREDIT
               MOVE WS-BALANCE    TO DR-BALANCE
               MOVE WS-CUMULATIVE TO DR-CUMULATIVE
               MOVE WS-M-COUNT    TO DR-COUNT
               PERFORM 2500-WRITE-DETAIL
               ADD WS-M-DEBIT  TO WS-Y-DEBIT
                   ON SIZE ERROR PERFORM 9200-OVERFLOW
               END-ADD
               ADD WS-M-CREDIT TO WS-Y-CREDIT
                   ON SIZE ERROR PERFORM 9200-OVERFLOW
               END-ADD
               ADD WS-M-COUNT  TO WS-Y-COUNT
               MOVE 0 TO WS-M-DEBIT WS-M-CREDIT WS-M-COUNT
           END-IF.

       2400-CLOSE-YEAR.
           IF NOT RUN-ABORTED
               COMPUTE WS-BALANCE = WS-Y-DEBIT - WS-Y-CREDIT
                   ON SIZE ERROR PERFORM 9200-OVERFLOW
               END-COMPUTE
               MOVE "Y"           TO DR-TYPE
               MOVE WS-CUR-YEAR   TO DR-YEAR
               MOVE 0             TO DR-MONTH
               MOVE WS-Y-DEBIT    TO DR-DEBIT
               MOVE WS-Y-CREDIT   TO DR-CREDIT
               MOVE WS-BALANCE    TO DR-BALANCE
               MOVE WS-CUMULATIVE TO DR-CUMULATIVE
               MOVE WS-Y-COUNT    TO DR-COUNT
               PERFORM 2500-WRITE-DETAIL
               ADD WS-Y-DEBIT  TO WS-T-DEBIT
                   ON SIZE ERROR PERFORM 9200-OVERFLOW
               END-ADD
               ADD WS-Y-CREDIT TO WS-T-CREDIT
                   ON SIZE ERROR PERFORM 9200-OVERFLOW
               END-ADD
               MOVE 0 TO WS-Y-DEBIT WS-Y-CREDIT WS-Y-COUNT
           END-IF.

       2500-WRITE-DETAIL.
           WRITE OUT-REC FROM WS-DETAIL-REC
           PERFORM 2600-CHECK-WRITE.

       2600-CHECK-WRITE.
           IF WS-OUT-STATUS NOT = "00"
               DISPLAY "LEDGER: WRITE ERROR, STATUS "
                   WS-OUT-STATUS UPON SYSERR
               MOVE 2 TO RETURN-CODE
               SET RUN-ABORTED TO TRUE
           END-IF.

       2900-REJECT-LINE.
           ADD 1 TO WS-REJ-CNT
           DISPLAY "LEDGER: LINE " WS-READ-CNT " REJECTED - "
               WS-REASON UPON SYSERR.

       3000-FINISH-RUN.
           IF NOT FIRST-ENTRY
               PERFORM 2300-CLOSE-MONTH
               PERFORM 2400-CLOSE-YEAR
           END-IF
           IF NOT RUN-ABORTED
               MOVE "T"          TO TR-TYPE
               MOVE WS-READ-CNT  TO TR-READ
               MOVE WS-OK-CNT    TO TR-ACCEPTED
               MOVE WS-REJ-CNT   TO TR-REJECTED
               MOVE WS-T-DEBIT   TO TR-DEBIT
               MOVE WS-T-CREDIT  TO TR-CREDIT
               MOVE WS-CUMULATIVE TO TR-BALANCE
               WRITE OUT-REC FROM WS-TRAILER-REC
               PERFORM 2600-CHECK-WRITE
               DISPLAY "LEDGER: READ=" WS-READ-CNT
                   " ACCEPTED=" WS-OK-CNT
                   " REJECTED=" WS-REJ-CNT
           END-IF.

       9000-CLOSE-FILES.
           CLOSE IN-FILE
           CLOSE OUT-FILE.

       9100-SET-RETURN-CODE.
           IF RETURN-CODE = 0 AND WS-REJ-CNT > 0
               MOVE 3 TO RETURN-CODE
           END-IF.

       9200-OVERFLOW.
           DISPLAY "LEDGER: AMOUNT OVERFLOW, RUN ABORTED" UPON SYSERR
           MOVE 4 TO RETURN-CODE
           SET RUN-ABORTED TO TRUE.

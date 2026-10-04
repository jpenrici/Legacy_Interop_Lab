       IDENTIFICATION DIVISION.
       PROGRAM-ID. LEDGER.

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT CSV-IN ASSIGN TO WS-PATH-CSV
               ORGANIZATION IS LINE SEQUENTIAL.
           SELECT DAT-OUT ASSIGN TO WS-PATH-DAT
               ORGANIZATION IS BINARY SEQUENTIAL
               STATUS IS WS-FILE-STATUS.

       DATA DIVISION.
       FILE SECTION.
       FD  CSV-IN.
       01  CSV-RECORD            PIC X(100).

       FD  DAT-OUT.
       01  DAT-RECORD.
           05 DAT-VALUE          PIC 9(05)V99 COMP.
           05 DAT-ID             PIC X(05).

       WORKING-STORAGE SECTION.
      *-----------------------------------------------------------------
      * PATH CONFIGURATION CONSTANTS (FIXED IN CODE)
      *-----------------------------------------------------------------
       01  WS-PATH-CSV.
           05 FILLER             PIC X(08) VALUE '../data/'.
           05 FILLER             PIC X(09) VALUE 'input.csv'.

       01  WS-PATH-DAT.
           05 FILLER             PIC X(08) VALUE '../data/'.
           05 FILLER             PIC X(10) VALUE 'output.dat'.

       01  WS-EOF                PIC X VALUE 'N'.
       01  WS-FILE-STATUS        PIC XX.
       01  WS-CMD                PIC X(10).
       01  WS-SUM                PIC 9(09)V99 VALUE 0.
       01  WS-AVG                PIC 9(07)V99 VALUE 0.
       01  WS-COUNT              PIC 9(05) VALUE 0.
       01  WS-NUM                PIC 9(05)V99.

       PROCEDURE DIVISION.
       MAIN-LOGIC.
           DISPLAY "=== LEGACY COMMAND SYSTEM ===".
           DISPLAY "READING FROM: " WS-PATH-CSV.
           DISPLAY "SAVING TO: " WS-PATH-DAT.

           MOVE 'READ' TO WS-CMD.
           PERFORM DISPATCH.

           MOVE 'CALCULATE' TO WS-CMD.
           PERFORM DISPATCH.

           MOVE 'SAVE' TO WS-CMD.
           PERFORM DISPATCH.

           MOVE 'BACKUP' TO WS-CMD.
           PERFORM DISPATCH.

           STOP RUN.

       DISPATCH.
           IF WS-CMD = 'READ'      GO TO RT-READ.
           IF WS-CMD = 'CALCULATE' GO TO RT-CALC.
           IF WS-CMD = 'SAVE'      GO TO RT-SAVE.
           IF WS-CMD = 'BACKUP'    GO TO RT-BKUP.
           GO TO END-DISPATCH.

       RT-READ.
           OPEN INPUT CSV-IN.
           OPEN OUTPUT DAT-OUT.
           MOVE 'N' TO WS-EOF.
           PERFORM READ-LOOP UNTIL WS-EOF = 'Y'.
           CLOSE CSV-IN.
           CLOSE DAT-OUT.
           DISPLAY "[OK] CSV READ AND CONVERTED TO BINARY DAT."
           GO TO END-DISPATCH.

       READ-LOOP.
           READ CSV-IN INTO CSV-RECORD
               AT END
                   MOVE 'Y' TO WS-EOF
               NOT AT END
                   MOVE CSV-RECORD(1:7) TO WS-NUM
                   ADD WS-NUM TO WS-SUM
                   ADD 1 TO WS-COUNT
                   MOVE WS-NUM TO DAT-VALUE
                   MOVE "VAL" TO DAT-ID
                   WRITE DAT-RECORD
           END-READ.

       RT-CALC.
           IF WS-COUNT > 0
               COMPUTE WS-AVG = WS-SUM / WS-COUNT
           ELSE
               MOVE 0 TO WS-AVG
           END-IF.
           DISPLAY "[CALC] TOTAL SUM: " WS-SUM.
           DISPLAY "[CALC] AVERAGE: " WS-AVG.
           GO TO END-DISPATCH.

       RT-SAVE.
           DISPLAY "[SAVE] DATA ALREADY PERSISTED TO BINARY DAT."
           GO TO END-DISPATCH.

       RT-BKUP.
           DISPLAY "[BACKUP] BACKUP COPY OF DAT FILE COMPLETED."
           GO TO END-DISPATCH.

       END-DISPATCH.
           EXIT.

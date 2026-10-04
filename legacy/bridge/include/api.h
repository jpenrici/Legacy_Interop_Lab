#pragma once

struct DatRecord {
    double value; // Corresponds to COBOL PIC 9(05)V99 COMP binary format
    char id[5];
};

#include "../include/api.h"

#include <stdio.h>
#include <stdlib.h>

int main()
{
    FILE* f = fopen("../data/output.dat", "rb");
    if (!f) {
        perror("Error opening data.dat");
        return 1;
    }

    struct DatRecord record;
    printf("--- READING COBOL DATA IN C ---\n");
    while (fread(&record, sizeof(struct DatRecord), 1, f) == 1) {
        printf("ID: %.5s | Value: %.2f\n", record.id, record.value);
    }

    fclose(f);
    return 0;
}

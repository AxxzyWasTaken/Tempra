#ifndef TEMPRA_SENSORS_H
#define TEMPRA_SENSORS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TempraTemperatureReader TempraTemperatureReader;

typedef enum {
    TEMPRA_TEMPERATURE_READER_OK = 0,
    TEMPRA_TEMPERATURE_READER_INVALID_ARGUMENT = 1,
    TEMPRA_TEMPERATURE_READER_ALLOCATION_FAILED = 2,
    TEMPRA_TEMPERATURE_READER_SMC_UNAVAILABLE = 3,
    TEMPRA_TEMPERATURE_READER_NO_CPU_SENSORS = 4,
    TEMPRA_TEMPERATURE_READER_READ_FAILED = 5
} TempraTemperatureReaderStatus;

TempraTemperatureReaderStatus TempraTemperatureReaderCreate(
    TempraTemperatureReader **reader
);
TempraTemperatureReaderStatus TempraTemperatureReaderReadCPU(
    TempraTemperatureReader *reader,
    double *temperatureCelsius
);
void TempraTemperatureReaderDestroy(TempraTemperatureReader *reader);

#ifdef __cplusplus
}
#endif

#endif

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

/// Samples the GPU energy counter the system power tools read.
///
/// The counter integrates energy, so power is a delta over a measured interval:
/// the first sample only establishes a baseline.
typedef struct TempraGPUEnergyReader TempraGPUEnergyReader;

typedef enum {
    TEMPRA_GPU_ENERGY_READER_OK = 0,
    TEMPRA_GPU_ENERGY_READER_INVALID_ARGUMENT = 1,
    TEMPRA_GPU_ENERGY_READER_ALLOCATION_FAILED = 2,
    TEMPRA_GPU_ENERGY_READER_UNAVAILABLE = 3,
    TEMPRA_GPU_ENERGY_READER_NEEDS_BASELINE = 4,
    TEMPRA_GPU_ENERGY_READER_READ_FAILED = 5
} TempraGPUEnergyReaderStatus;

TempraGPUEnergyReaderStatus TempraGPUEnergyReaderCreate(
    TempraGPUEnergyReader **reader
);

/// Writes the mean GPU power in watts since the previous successful sample.
TempraGPUEnergyReaderStatus TempraGPUEnergyReaderSample(
    TempraGPUEnergyReader *reader,
    double *watts
);

void TempraGPUEnergyReaderDestroy(TempraGPUEnergyReader *reader);

#ifdef __cplusplus
}
#endif

#endif

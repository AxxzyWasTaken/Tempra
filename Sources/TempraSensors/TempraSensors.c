// AppleSMC access is adapted from the MIT-licensed MacMonitor SMC reader.

#include "TempraSensors.h"

#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

#define TEMPRA_SMC_SELECTOR 2
#define TEMPRA_SMC_READ_BYTES 5
#define TEMPRA_SMC_READ_INDEX 8
#define TEMPRA_SMC_READ_KEY_INFO 9
#define TEMPRA_SMC_FLOAT_TYPE 0x666c7420U
#define TEMPRA_SMC_SP78_TYPE 0x73703738U
#define TEMPRA_MAX_CPU_KEYS 512

typedef struct {
    char major;
    char minor;
    char build;
    char reserved;
    uint16_t release;
} TempraSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuLimit;
    uint32_t gpuLimit;
    uint32_t memoryLimit;
} TempraSMCPowerLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} TempraSMCKeyInfo;

typedef struct {
    uint32_t key;
    TempraSMCVersion version;
    TempraSMCPowerLimit powerLimit;
    TempraSMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    char bytes[32];
} TempraSMCKeyData;

typedef struct {
    char name[5];
    TempraSMCKeyInfo info;
} TempraCachedSMCKey;

struct TempraTemperatureReader {
    io_connect_t smcConnection;
    TempraCachedSMCKey keys[TEMPRA_MAX_CPU_KEYS];
    size_t keyCount;
};

static uint32_t TempraFourCharacterCode(const char key[4]) {
    return ((uint32_t)(uint8_t)key[0] << 24)
        | ((uint32_t)(uint8_t)key[1] << 16)
        | ((uint32_t)(uint8_t)key[2] << 8)
        | (uint32_t)(uint8_t)key[3];
}

static bool TempraIsValidTemperature(double value) {
    return isfinite(value) && value >= 1.0 && value <= 125.0;
}

static kern_return_t TempraSMCCall(
    io_connect_t connection,
    TempraSMCKeyData *input,
    TempraSMCKeyData *output
) {
    size_t outputSize = sizeof(*output);
    return IOConnectCallStructMethod(
        connection,
        TEMPRA_SMC_SELECTOR,
        input,
        sizeof(*input),
        output,
        &outputSize
    );
}

static io_connect_t TempraOpenSMC(void) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        return IO_OBJECT_NULL;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == kIOReturnSuccess ? connection : IO_OBJECT_NULL;
}

static bool TempraReadSMCKeyInfo(
    io_connect_t connection,
    const char key[4],
    TempraSMCKeyInfo *info
) {
    TempraSMCKeyData input = {0};
    TempraSMCKeyData output = {0};
    input.key = TempraFourCharacterCode(key);
    input.data8 = TEMPRA_SMC_READ_KEY_INFO;
    if (TempraSMCCall(connection, &input, &output) != kIOReturnSuccess) {
        return false;
    }
    *info = output.keyInfo;
    return true;
}

static bool TempraReadSMCBytes(
    io_connect_t connection,
    const TempraCachedSMCKey *key,
    char bytes[32]
) {
    TempraSMCKeyData input = {0};
    TempraSMCKeyData output = {0};
    input.key = TempraFourCharacterCode(key->name);
    input.keyInfo.dataSize = key->info.dataSize;
    input.data8 = TEMPRA_SMC_READ_BYTES;
    if (TempraSMCCall(connection, &input, &output) != kIOReturnSuccess) {
        return false;
    }
    memcpy(bytes, output.bytes, sizeof(output.bytes));
    return true;
}

static bool TempraReadSMCTemperature(
    io_connect_t connection,
    const TempraCachedSMCKey *key,
    double *value
) {
    char bytes[32] = {0};
    if (!TempraReadSMCBytes(connection, key, bytes)) {
        return false;
    }

    double decoded = NAN;
    if (key->info.dataType == TEMPRA_SMC_FLOAT_TYPE && key->info.dataSize >= 4) {
        float number = 0;
        memcpy(&number, bytes, sizeof(number));
        decoded = number;
    } else if (key->info.dataType == TEMPRA_SMC_SP78_TYPE && key->info.dataSize >= 2) {
        int16_t raw = (int16_t)(((uint16_t)(uint8_t)bytes[0] << 8)
            | (uint16_t)(uint8_t)bytes[1]);
        decoded = (double)raw / 256.0;
    }

    if (!TempraIsValidTemperature(decoded)) {
        return false;
    }
    *value = decoded;
    return true;
}

static uint32_t TempraReadSMCKeyCount(io_connect_t connection) {
    TempraCachedSMCKey key = { .name = "#KEY" };
    if (!TempraReadSMCKeyInfo(connection, key.name, &key.info)) {
        return 0;
    }
    char bytes[32] = {0};
    if (!TempraReadSMCBytes(connection, &key, bytes)) {
        return 0;
    }
    return ((uint32_t)(uint8_t)bytes[0] << 24)
        | ((uint32_t)(uint8_t)bytes[1] << 16)
        | ((uint32_t)(uint8_t)bytes[2] << 8)
        | (uint32_t)(uint8_t)bytes[3];
}

static bool TempraReadSMCKeyAtIndex(
    io_connect_t connection,
    uint32_t index,
    char key[5]
) {
    TempraSMCKeyData input = {0};
    TempraSMCKeyData output = {0};
    input.data8 = TEMPRA_SMC_READ_INDEX;
    input.data32 = index;
    if (TempraSMCCall(connection, &input, &output) != kIOReturnSuccess) {
        return false;
    }
    key[0] = (char)((output.key >> 24) & 0xff);
    key[1] = (char)((output.key >> 16) & 0xff);
    key[2] = (char)((output.key >> 8) & 0xff);
    key[3] = (char)(output.key & 0xff);
    key[4] = '\0';
    return true;
}

static bool TempraIsAppleSilicon(void) {
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) == 0
        && translated == 1) {
        return true;
    }

    char brand[128] = {0};
    size = sizeof(brand);
    if (sysctlbyname("machdep.cpu.brand_string", brand, &size, NULL, 0) == 0) {
        return strstr(brand, "Apple") != NULL;
    }

#if defined(__arm64__)
    return true;
#else
    return false;
#endif
}

static bool TempraIsCPUKey(const char key[5], bool appleSilicon) {
    if (appleSilicon) {
        return (key[0] == 'T' && key[1] == 'p')
            || (key[0] == 'T' && key[1] == 'e')
            || (key[0] == 'T' && key[1] == 's');
    }
    return key[0] == 'T' && key[1] == 'C';
}

static void TempraCacheSMCKeys(TempraTemperatureReader *reader) {
    if (reader->smcConnection == IO_OBJECT_NULL) {
        return;
    }

    bool appleSilicon = TempraIsAppleSilicon();
    uint32_t count = TempraReadSMCKeyCount(reader->smcConnection);
    for (uint32_t index = 0;
         index < count && reader->keyCount < TEMPRA_MAX_CPU_KEYS;
         index++) {
        char key[5] = {0};
        if (!TempraReadSMCKeyAtIndex(reader->smcConnection, index, key)
            || !TempraIsCPUKey(key, appleSilicon)) {
            continue;
        }

        TempraSMCKeyInfo info = {0};
        if (!TempraReadSMCKeyInfo(reader->smcConnection, key, &info)
            || (info.dataType != TEMPRA_SMC_FLOAT_TYPE
                && info.dataType != TEMPRA_SMC_SP78_TYPE)) {
            continue;
        }

        TempraCachedSMCKey cached = {0};
        memcpy(cached.name, key, sizeof(cached.name));
        cached.info = info;

        double probe = 0;
        if (!TempraReadSMCTemperature(reader->smcConnection, &cached, &probe)) {
            continue;
        }
        reader->keys[reader->keyCount++] = cached;
    }
}

static bool TempraReadSMCAverage(TempraTemperatureReader *reader, double *value) {
    double sum = 0;
    size_t count = 0;
    for (size_t index = 0; index < reader->keyCount; index++) {
        double current = 0;
        if (TempraReadSMCTemperature(
                reader->smcConnection,
                &reader->keys[index],
                &current)) {
            sum += current;
            count++;
        }
    }
    if (count == 0) {
        return false;
    }
    *value = sum / (double)count;
    return TempraIsValidTemperature(*value);
}

TempraTemperatureReaderStatus TempraTemperatureReaderCreate(
    TempraTemperatureReader **reader
) {
    if (reader == NULL) {
        return TEMPRA_TEMPERATURE_READER_INVALID_ARGUMENT;
    }
    *reader = NULL;

    TempraTemperatureReader *created = calloc(1, sizeof(*created));
    if (created == NULL) {
        return TEMPRA_TEMPERATURE_READER_ALLOCATION_FAILED;
    }
    created->smcConnection = TempraOpenSMC();
    if (created->smcConnection == IO_OBJECT_NULL) {
        free(created);
        return TEMPRA_TEMPERATURE_READER_SMC_UNAVAILABLE;
    }
    TempraCacheSMCKeys(created);
    if (created->keyCount == 0) {
        IOServiceClose(created->smcConnection);
        free(created);
        return TEMPRA_TEMPERATURE_READER_NO_CPU_SENSORS;
    }
    *reader = created;
    return TEMPRA_TEMPERATURE_READER_OK;
}

TempraTemperatureReaderStatus TempraTemperatureReaderReadCPU(
    TempraTemperatureReader *reader,
    double *temperatureCelsius
) {
    if (reader == NULL || temperatureCelsius == NULL) {
        return TEMPRA_TEMPERATURE_READER_INVALID_ARGUMENT;
    }
    return TempraReadSMCAverage(reader, temperatureCelsius)
        ? TEMPRA_TEMPERATURE_READER_OK
        : TEMPRA_TEMPERATURE_READER_READ_FAILED;
}

void TempraTemperatureReaderDestroy(TempraTemperatureReader *reader) {
    if (reader == NULL) {
        return;
    }
    if (reader->smcConnection != IO_OBJECT_NULL) {
        IOServiceClose(reader->smcConnection);
    }
    free(reader);
}

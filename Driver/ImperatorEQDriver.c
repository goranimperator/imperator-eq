#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <string.h>
#include <stdatomic.h>

#define kDeviceName "Imperator EQ"
#define kDeviceManufacturer "Goran Imperator"
#define kDeviceUID "ImperatorEQ_Device_UID"
#define kDeviceModelUID "ImperatorEQ_Model_UID"

#define kObjectID_Device 2
#define kObjectID_Stream_Output 3
#define kObjectID_Stream_Input 4
#define kObjectID_Volume_Master 5

#define kNumChannels 2
#define kSampleRate 48000.0
#define kBitsPerChannel 32
#define kBytesPerFrame (kNumChannels * (kBitsPerChannel / 8))
#define kRingBufferFrames 65536

static os_log_t sLog = NULL;

#pragma mark - Driver State

typedef struct {
    AudioServerPlugInDriverInterface** mInterface;
    AudioServerPlugInHostRef mHost;
    UInt32 mRefCount;
    atomic_bool mIOIsRunning;
    UInt64 mIOStartTick;
    Float64 mTicksPerFrame;
    UInt64 mIOCounter;
    Float32 mRingBuffer[kRingBufferFrames * kNumChannels];
    UInt64 mRingWritePos;
    Float32 mVolume;
    Boolean mMuted;
} ImperatorDriver;

static ImperatorDriver* sDriver = NULL;

#pragma mark - IUnknown

static HRESULT imp_QueryInterface(void* inSelf, REFIID inUUID, LPVOID* outInterface) {
    CFUUIDRef interfaceUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(interfaceUUID, kAudioServerPlugInTypeUUID) || CFEqual(interfaceUUID, IUnknownUUID)) {
        ImperatorDriver* driver = (ImperatorDriver*)inSelf;
        driver->mRefCount++;
        *outInterface = inSelf;
        result = S_OK;
    }

    CFRelease(interfaceUUID);
    return result;
}

static ULONG imp_AddRef(void* inSelf) {
    ImperatorDriver* driver = (ImperatorDriver*)inSelf;
    return ++driver->mRefCount;
}

static ULONG imp_Release(void* inSelf) {
    ImperatorDriver* driver = (ImperatorDriver*)inSelf;
    UInt32 count = --driver->mRefCount;
    if (count == 0) {
        free(driver->mInterface);
        free(driver);
        sDriver = NULL;
    }
    return count;
}

#pragma mark - Basic Operations

static OSStatus imp_Initialize(AudioServerPlugInDriverRef inSelf, AudioServerPlugInHostRef inHost) {
    ImperatorDriver* driver = (ImperatorDriver*)inSelf;
    driver->mHost = inHost;
    driver->mVolume = 1.0f;
    driver->mMuted = false;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 nsPerTick = (Float64)timebase.numer / (Float64)timebase.denom;
    driver->mTicksPerFrame = (1e9 / kSampleRate) / nsPerTick;

    return kAudioHardwareNoError;
}

static OSStatus imp_CreateDevice(AudioServerPlugInDriverRef inSelf, CFDictionaryRef inDesc,
                                  const AudioServerPlugInClientInfo* inClient, AudioObjectID* outID) {
    (void)inSelf; (void)inDesc; (void)inClient; (void)outID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus imp_DestroyDevice(AudioServerPlugInDriverRef inSelf, AudioObjectID inID) {
    (void)inSelf; (void)inID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus imp_AddDeviceClient(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                     const AudioServerPlugInClientInfo* inClient) {
    (void)inSelf; (void)inID; (void)inClient;
    return kAudioHardwareNoError;
}

static OSStatus imp_RemoveDeviceClient(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                        const AudioServerPlugInClientInfo* inClient) {
    (void)inSelf; (void)inID; (void)inClient;
    return kAudioHardwareNoError;
}

static OSStatus imp_PerformDeviceConfigChange(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                               UInt64 inAction, void* inData) {
    (void)inSelf; (void)inID; (void)inAction; (void)inData;
    return kAudioHardwareNoError;
}

static OSStatus imp_AbortDeviceConfigChange(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                             UInt64 inAction, void* inData) {
    (void)inSelf; (void)inID; (void)inAction; (void)inData;
    return kAudioHardwareNoError;
}

#pragma mark - Property Helpers

static Boolean isPlugInProperty(AudioObjectID id, const AudioObjectPropertyAddress* addr) {
    return id == kAudioObjectPlugInObject;
}

static Boolean isDeviceProperty(AudioObjectID id) {
    return id == kObjectID_Device;
}

static Boolean isStreamProperty(AudioObjectID id) {
    return id == kObjectID_Stream_Output || id == kObjectID_Stream_Input;
}

#pragma mark - HasProperty

static Boolean imp_HasProperty(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                pid_t inClient, const AudioObjectPropertyAddress* inAddr) {
    (void)inSelf; (void)inClient;

    if (isPlugInProperty(inID, inAddr)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle:
                return true;
        }
    }

    if (isDeviceProperty(inID)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyIcon:
            case kAudioDevicePropertyPreferredChannelsForStereo:
                return true;
        }
    }

    if (isStreamProperty(inID)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
        }
    }

    return false;
}

#pragma mark - IsPropertySettable

static OSStatus imp_IsPropertySettable(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                        pid_t inClient, const AudioObjectPropertyAddress* inAddr,
                                        Boolean* outSettable) {
    (void)inSelf; (void)inClient;
    *outSettable = false;
    return kAudioHardwareNoError;
}

#pragma mark - GetPropertyDataSize

static OSStatus imp_GetPropertyDataSize(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                         pid_t inClient, const AudioObjectPropertyAddress* inAddr,
                                         UInt32 inQualSize, const void* inQual, UInt32* outSize) {
    (void)inSelf; (void)inClient; (void)inQualSize; (void)inQual;

    if (isPlugInProperty(inID, inAddr)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
                *outSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:
                *outSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *outSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice:
                *outSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
        }
    }

    if (isDeviceProperty(inID)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
                *outSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *outSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                *outSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyIsHidden:
                *outSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                *outSize = sizeof(AudioObjectID) * 2;
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
                *outSize = sizeof(AudioObjectID) * 2;
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outSize = 0;
                return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                *outSize = sizeof(Float64);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outSize = sizeof(AudioValueRange);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                *outSize = sizeof(UInt32) * 2;
                return kAudioHardwareNoError;
            case kAudioDevicePropertyIcon:
                *outSize = sizeof(CFURLRef);
                return kAudioHardwareNoError;
        }
    }

    if (isStreamProperty(inID)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
                *outSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
                *outSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outSize = sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
        }
    }

    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - GetPropertyData

static AudioStreamBasicDescription makeStreamDesc(void) {
    AudioStreamBasicDescription desc = {0};
    desc.mSampleRate = kSampleRate;
    desc.mFormatID = kAudioFormatLinearPCM;
    desc.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    desc.mBytesPerPacket = kBytesPerFrame;
    desc.mFramesPerPacket = 1;
    desc.mBytesPerFrame = kBytesPerFrame;
    desc.mChannelsPerFrame = kNumChannels;
    desc.mBitsPerChannel = kBitsPerChannel;
    return desc;
}

static OSStatus imp_GetPropertyData(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                     pid_t inClient, const AudioObjectPropertyAddress* inAddr,
                                     UInt32 inQualSize, const void* inQual,
                                     UInt32 inDataSize, UInt32* ioSize, void* outData) {
    (void)inSelf; (void)inClient; (void)inQualSize; (void)inQual; (void)inDataSize;

    // Plugin properties
    if (isPlugInProperty(inID, inAddr)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID;
                *ioSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioPlugInClassID;
                *ioSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kAudioObjectUnknown;
                *ioSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                *((CFStringRef*)outData) = CFSTR(kDeviceManufacturer);
                *ioSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *((AudioObjectID*)outData) = kObjectID_Device;
                *ioSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                CFStringRef uid = *((CFStringRef*)inQual);
                if (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) {
                    *((AudioObjectID*)outData) = kObjectID_Device;
                } else {
                    *((AudioObjectID*)outData) = kAudioObjectUnknown;
                }
                *ioSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            }
            case kAudioPlugInPropertyResourceBundle:
                *((CFStringRef*)outData) = CFSTR("");
                *ioSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
        }
    }

    // Device properties
    if (isDeviceProperty(inID)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID;
                *ioSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioDeviceClassID;
                *ioSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kAudioObjectPlugInObject;
                *ioSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                *((CFStringRef*)outData) = CFSTR(kDeviceName);
                *ioSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                *((CFStringRef*)outData) = CFSTR(kDeviceManufacturer);
                *ioSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceUID:
                *((CFStringRef*)outData) = CFSTR(kDeviceUID);
                *ioSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyModelUID:
                *((CFStringRef*)outData) = CFSTR(kDeviceModelUID);
                *ioSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
                *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                *((AudioObjectID*)outData) = kObjectID_Device;
                *ioSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyClockDomain:
                *((UInt32*)outData) = 0;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsAlive:
                *((UInt32*)outData) = 1;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsRunning:
                *((UInt32*)outData) = atomic_load(&sDriver->mIOIsRunning) ? 1 : 0;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                *((UInt32*)outData) = 1;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                *((UInt32*)outData) = 1;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyLatency:
                *((UInt32*)outData) = 0;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams: {
                AudioObjectID* ids = (AudioObjectID*)outData;
                if (inAddr->mScope == kAudioObjectPropertyScopeInput) {
                    ids[0] = kObjectID_Stream_Input;
                    *ioSize = sizeof(AudioObjectID);
                } else if (inAddr->mScope == kAudioObjectPropertyScopeOutput) {
                    ids[0] = kObjectID_Stream_Output;
                    *ioSize = sizeof(AudioObjectID);
                } else {
                    ids[0] = kObjectID_Stream_Output;
                    ids[1] = kObjectID_Stream_Input;
                    *ioSize = sizeof(AudioObjectID) * 2;
                }
                return kAudioHardwareNoError;
            }
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID* ids = (AudioObjectID*)outData;
                ids[0] = kObjectID_Stream_Output;
                ids[1] = kObjectID_Stream_Input;
                *ioSize = sizeof(AudioObjectID) * 2;
                return kAudioHardwareNoError;
            }
            case kAudioObjectPropertyControlList:
                *ioSize = 0;
                return kAudioHardwareNoError;
            case kAudioDevicePropertySafetyOffset:
                *((UInt32*)outData) = 0;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                *((Float64*)outData) = kSampleRate;
                *ioSize = sizeof(Float64);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange* range = (AudioValueRange*)outData;
                range->mMinimum = kSampleRate;
                range->mMaximum = kSampleRate;
                *ioSize = sizeof(AudioValueRange);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyIsHidden:
                *((UInt32*)outData) = 0;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *((UInt32*)outData) = kRingBufferFrames;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32* channels = (UInt32*)outData;
                channels[0] = 1;
                channels[1] = 2;
                *ioSize = sizeof(UInt32) * 2;
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyIcon:
                *ioSize = 0;
                return kAudioHardwareUnknownPropertyError;
        }
    }

    // Stream properties
    if (isStreamProperty(inID)) {
        switch (inAddr->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID;
                *ioSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioStreamClassID;
                *ioSize = sizeof(AudioClassID);
                return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kObjectID_Device;
                *ioSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:
                *((UInt32*)outData) = 1;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyDirection:
                *((UInt32*)outData) = (inID == kObjectID_Stream_Output) ? 0 : 1;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyTerminalType:
                *((UInt32*)outData) = (inID == kObjectID_Stream_Output)
                    ? kAudioStreamTerminalTypeSpeaker
                    : kAudioStreamTerminalTypeMicrophone;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyStartingChannel:
                *((UInt32*)outData) = 1;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyLatency:
                *((UInt32*)outData) = 0;
                *ioSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *((AudioStreamBasicDescription*)outData) = makeStreamDesc();
                *ioSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription* desc = (AudioStreamRangedDescription*)outData;
                desc->mFormat = makeStreamDesc();
                desc->mSampleRateRange.mMinimum = kSampleRate;
                desc->mSampleRateRange.mMaximum = kSampleRate;
                *ioSize = sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
            }
        }
    }

    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - SetPropertyData

static OSStatus imp_SetPropertyData(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                     pid_t inClient, const AudioObjectPropertyAddress* inAddr,
                                     UInt32 inQualSize, const void* inQual,
                                     UInt32 inDataSize, const void* inData) {
    (void)inSelf; (void)inClient; (void)inQualSize; (void)inQual;
    (void)inID; (void)inAddr; (void)inDataSize; (void)inData;
    return kAudioHardwareNoError;
}

#pragma mark - IO Operations

static OSStatus imp_StartIO(AudioServerPlugInDriverRef inSelf, AudioObjectID inID, UInt32 inClientID) {
    (void)inID; (void)inClientID;
    ImperatorDriver* driver = (ImperatorDriver*)inSelf;

    if (!atomic_load(&driver->mIOIsRunning)) {
        driver->mIOStartTick = mach_absolute_time();
        driver->mIOCounter = 0;
        driver->mRingWritePos = 0;
        memset(driver->mRingBuffer, 0, sizeof(driver->mRingBuffer));
        atomic_store(&driver->mIOIsRunning, true);
    }

    return kAudioHardwareNoError;
}

static OSStatus imp_StopIO(AudioServerPlugInDriverRef inSelf, AudioObjectID inID, UInt32 inClientID) {
    (void)inID; (void)inClientID;
    ImperatorDriver* driver = (ImperatorDriver*)inSelf;
    atomic_store(&driver->mIOIsRunning, false);
    return kAudioHardwareNoError;
}

static OSStatus imp_GetZeroTimeStamp(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                      UInt32 inClientID, Float64* outSampleTime,
                                      UInt64* outHostTime, UInt64* outSeed) {
    (void)inID; (void)inClientID;
    ImperatorDriver* driver = (ImperatorDriver*)inSelf;

    UInt64 counter = driver->mIOCounter;
    UInt64 period = kRingBufferFrames;

    *outSampleTime = counter * period;
    *outHostTime = driver->mIOStartTick + (UInt64)(counter * period * driver->mTicksPerFrame);
    *outSeed = 1;

    return kAudioHardwareNoError;
}

static OSStatus imp_WillDoIOOperation(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                       UInt32 inClientID, UInt32 inOperationID,
                                       Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inSelf; (void)inID; (void)inClientID;

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationWriteMix:
        case kAudioServerPlugInIOOperationReadInput:
            *outWillDo = true;
            *outWillDoInPlace = true;
            break;
        default:
            *outWillDo = false;
            *outWillDoInPlace = true;
            break;
    }

    return kAudioHardwareNoError;
}

static OSStatus imp_BeginIOOperation(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                      UInt32 inClientID, UInt32 inOperationID,
                                      UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inSelf; (void)inID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus imp_DoIOOperation(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                   AudioObjectID inStreamID, UInt32 inClientID,
                                   UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                   void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inID; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;
    ImperatorDriver* driver = (ImperatorDriver*)inSelf;

    Float32* buffer = (Float32*)ioMainBuffer;
    UInt32 totalSamples = inIOBufferFrameSize * kNumChannels;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 writePos = driver->mRingWritePos;
        for (UInt32 i = 0; i < totalSamples; i++) {
            driver->mRingBuffer[(writePos + i) % (kRingBufferFrames * kNumChannels)] = buffer[i];
        }
        driver->mRingWritePos = (writePos + totalSamples) % (kRingBufferFrames * kNumChannels);
    }
    else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        UInt64 readPos = driver->mRingWritePos;
        if (readPos >= totalSamples) {
            readPos -= totalSamples;
        } else {
            readPos = (kRingBufferFrames * kNumChannels) - (totalSamples - readPos);
        }
        for (UInt32 i = 0; i < totalSamples; i++) {
            buffer[i] = driver->mRingBuffer[(readPos + i) % (kRingBufferFrames * kNumChannels)];
        }
    }

    return kAudioHardwareNoError;
}

static OSStatus imp_EndIOOperation(AudioServerPlugInDriverRef inSelf, AudioObjectID inID,
                                    UInt32 inClientID, UInt32 inOperationID,
                                    UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inSelf; (void)inID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        ImperatorDriver* driver = (ImperatorDriver*)inSelf;
        driver->mIOCounter++;
    }

    return kAudioHardwareNoError;
}

#pragma mark - Driver Interface

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL, // _reserved
    imp_QueryInterface,
    imp_AddRef,
    imp_Release,
    imp_Initialize,
    imp_CreateDevice,
    imp_DestroyDevice,
    imp_AddDeviceClient,
    imp_RemoveDeviceClient,
    imp_PerformDeviceConfigChange,
    imp_AbortDeviceConfigChange,
    imp_HasProperty,
    imp_IsPropertySettable,
    imp_GetPropertyDataSize,
    imp_GetPropertyData,
    imp_SetPropertyData,
    imp_StartIO,
    imp_StopIO,
    imp_GetZeroTimeStamp,
    imp_WillDoIOOperation,
    imp_BeginIOOperation,
    imp_DoIOOperation,
    imp_EndIOOperation
};

void* ImperatorEQDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;

    if (sLog == NULL) {
        sLog = os_log_create("com.goranimperator.ImperatorEQDriver", "Driver");
    }

    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    ImperatorDriver* driver = (ImperatorDriver*)calloc(1, sizeof(ImperatorDriver));
    if (!driver) return NULL;

    AudioServerPlugInDriverInterface** interface = (AudioServerPlugInDriverInterface**)calloc(1, sizeof(AudioServerPlugInDriverInterface*));
    if (!interface) { free(driver); return NULL; }

    *interface = &gDriverInterface;
    driver->mInterface = interface;
    driver->mRefCount = 1;
    driver->mVolume = 1.0f;

    sDriver = driver;

    os_log(sLog, "Imperator EQ Driver created");

    return interface;
}

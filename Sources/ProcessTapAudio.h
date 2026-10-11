#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum EZProcessTapStage {
    EZTapNone = 0, EZTapConsent, EZTapUnsupportedOS, EZTapInspectOutput,
    EZTapOwnProcess, EZTapCreate, EZTapDescription, EZTapAggregate,
    EZTapFormats, EZTapListeners, EZTapCreateIO, EZTapStartIO,
    EZTapCallbackFormat, EZTapTopology, EZTapTimeout, EZTapCleanup
};
// ReadProgress.status details for EZTapTimeout; creation failures continue to
// report the original CoreAudio OSStatus in EZProcessTapFailure.status.
enum EZProcessTapTimeoutReason {
    EZTapTimeoutUnknown = 0, EZTapTimeoutOwnerLease, EZTapTimeoutFirstPCM
};
typedef struct { int32_t stage; int32_t status; } EZProcessTapFailure;
typedef struct {
    uint64_t callbacks;
    uint64_t validFrames;
    int32_t ready;
    int32_t stage;
    int32_t status;
} EZProcessTapProgress;
enum EZProcessTapCleanupOperation {
    EZTapCleanupNone = 0, EZTapCleanupStopIO, EZTapCleanupDestroyIO,
    EZTapCleanupRemoveListener, EZTapCleanupDestroyAggregate, EZTapCleanupDestroyTap,
    EZTapCleanupInspectAggregate, EZTapCleanupInspectTap, EZTapCleanupInspectListener,
    EZTapCleanupWaitCallbacks
};
typedef struct {
    int32_t operation;
    uint32_t objectID;
    uint32_t selector;
    int32_t status;
} EZProcessTapCleanupFailure;
int EZProcessTapAvailable(void);
// Start intent is scoped to the current output and never persisted.
// Missing intent returns before any CoreAudio call; OS permission is separate.
void *EZProcessTapCreate(uint32_t outputDevice, int consentConfirmed, float initialGain, int initialMuted, EZProcessTapFailure *error);
int EZProcessTapSetGain(void *session, float gain, int muted);
int EZProcessTapSnapshot(void *session, float *gain, int *muted);
int EZProcessTapHealthy(void *session);
int EZProcessTapReadProgress(void *session, EZProcessTapProgress *progress);
void EZProcessTapHeartbeat(void *session);
void EZProcessTapPause(void *session);
// Stops replay before releasing the original-stream mute. Failure retains a
// silent context; it never destroys the tap while replay could still be active.
int EZProcessTapDestroy(void *session);
// Retry only already quarantined cleanup, never create or start audio objects.
// Returns 1 when no blocking cleanup remains; success clears the output detail.
int EZProcessTapRetryCleanup(EZProcessTapCleanupFailure *failure);
// Read the most recent cleanup API/probe failure without changing audio state.
int EZProcessTapReadCleanupFailure(EZProcessTapCleanupFailure *failure);
#ifdef __cplusplus
}
#endif

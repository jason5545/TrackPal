// MultitouchSupport.framework private API
#ifndef MultitouchSupport_h
#define MultitouchSupport_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MTDeviceRef must be void *, not a struct pointer.
typedef void *MTDeviceRef;

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

// Touch states: 1 hovering, 2 starting, 3 making contact, 4 touching,
// 5 moving with velocity, 6 lifting, 7 released.
typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int fingerId;
    int handId;
    MTVector normalized;
    float size;
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int zero2;
    int zero3;
    float density;
} MTTouch;

typedef struct {
    int deviceID;
    int reserved0;
    double timestamp;
    float normalizedX;
    float normalizedY;
    float x;
    float y;
    float force;
    int reserved1;
} MTForceCentroid;

typedef void (*MTContactCallbackFunction)(MTDeviceRef _Nullable device, MTTouch * _Nullable touches, int numTouches, double timestamp, int frame);
typedef void (*MTContactCallbackFunctionWithRefcon)(MTDeviceRef _Nullable device, MTTouch * _Nullable touches, int numTouches, double timestamp, int frame, void * _Nullable refcon);
typedef void (*MTForceCentroidCallbackFunctionWithRefcon)(MTDeviceRef _Nullable device, MTForceCentroid * _Nullable centroid, void * _Nullable refcon);

CF_RETURNS_RETAINED CFArrayRef _Nullable MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTUnregisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTRegisterContactFrameCallbackWithRefcon(MTDeviceRef device, MTContactCallbackFunctionWithRefcon callback, void * _Nullable refcon);
// The private framework exports one unregister symbol for both callback forms.
// Keep the refcon function-pointer type at Swift call sites, then erase it only
// inside this C shim when unregistering the exact same callback address.
static inline void MTUnregisterContactFrameCallbackWithRefcon(
    MTDeviceRef device,
    MTContactCallbackFunctionWithRefcon callback
) {
    MTUnregisterContactFrameCallback(device, (MTContactCallbackFunction)callback);
}
bool MTRegisterForceCentroidCallbackWithRefcon(MTDeviceRef device, MTForceCentroidCallbackFunctionWithRefcon callback, void * _Nullable refcon);
void MTUnregisterForceCentroidCallback(MTDeviceRef device, MTForceCentroidCallbackFunctionWithRefcon callback);
void MTDeviceStart(MTDeviceRef device, int mode);
void MTDeviceStop(MTDeviceRef device);
bool MTDeviceIsRunning(MTDeviceRef device);
bool MTDeviceSupportsForce(MTDeviceRef device);

// WARNING: these crash on some systems. Declared for reference; do not call.
int MTDeviceGetDeviceID(MTDeviceRef device);
int MTDeviceGetFamilyID(MTDeviceRef device);
bool MTDeviceIsBuiltIn(MTDeviceRef device);
OSStatus MTDeviceGetSensorSurfaceDimensions(MTDeviceRef device, int *width, int *height);

NS_ASSUME_NONNULL_END

#endif /* MultitouchSupport_h */

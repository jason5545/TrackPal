// MultitouchSupport.framework private API
#ifndef MultitouchSupport_h
#define MultitouchSupport_h

#import <Foundation/Foundation.h>

typedef void *MTDeviceRef;

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

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

typedef void (*MTContactCallbackFunction)(MTDeviceRef device, MTTouch *touches, int numTouches, double timestamp, int frame);
typedef void (*MTContactCallbackFunctionWithRefcon)(MTDeviceRef device, MTTouch *touches, int numTouches, double timestamp, int frame, void *refcon);

// Functions
CF_RETURNS_RETAINED CFArrayRef _Nullable MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTUnregisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTRegisterContactFrameCallbackWithRefcon(MTDeviceRef device, MTContactCallbackFunctionWithRefcon callback, void *refcon);
void MTDeviceStart(MTDeviceRef device, int mode);
void MTDeviceStop(MTDeviceRef device);
bool MTDeviceIsRunning(MTDeviceRef device);
int MTDeviceGetDeviceID(MTDeviceRef device);
int MTDeviceGetFamilyID(MTDeviceRef device);
bool MTDeviceIsBuiltIn(MTDeviceRef device);
OSStatus MTDeviceGetSensorSurfaceDimensions(MTDeviceRef device, int *width, int *height);

#endif /* MultitouchSupport_h */

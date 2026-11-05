// libnvdefault.dylib: loaded into an app that KBColor opens with "NVIDIA ile aç" (DYLD_INSERT_LIBRARIES).
// Interposes Metal's device lookup so the app's default GPU is the NVIDIA card instead of the GPU that drives
// the main display (the Intel iGPU on this laptop), and lists the NVIDIA card first for apps that take the first
// device. With no NVIDIA Metal device it changes nothing. Child processes inherit the variable, so games started
// from a launcher opened this way get the NVIDIA card too.
#import <Metal/Metal.h>
#include <string.h>

#define INTERPOSE(_new, _old) __attribute__((used)) static struct { const void *n; const void *o; } interpose_##_old \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_new, (const void *)(unsigned long)&_old };

static BOOL isNvidia(id<MTLDevice> d) { return strcasestr(d.name.UTF8String ?: "", "NVIDIA") != NULL; }

// Both return +1 like the Metal functions they replace (Create/Copy rule). Calls made from this library are not
// interposed, so these reach Metal itself.
static NSArray<id<MTLDevice>> *nvdef_copy_all(void) NS_RETURNS_RETAINED
{
    NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
    NSUInteger i = [all indexOfObjectPassingTest:^BOOL(id<MTLDevice> d, NSUInteger idx, BOOL *stop) { return isNvidia(d); }];
    if (i == NSNotFound || i == 0) return all;
    NSMutableArray *m = [all mutableCopy];
    id<MTLDevice> nv = m[i];
    [m removeObjectAtIndex:i];
    [m insertObject:nv atIndex:0];
    return m;
}

static id<MTLDevice> nvdef_default(void) NS_RETURNS_RETAINED
{
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if (isNvidia(d)) return d;
    return MTLCreateSystemDefaultDevice();
}

INTERPOSE(nvdef_copy_all, MTLCopyAllDevices)
INTERPOSE(nvdef_default, MTLCreateSystemDefaultDevice)

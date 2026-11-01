//
//  KBColor.cpp
//  Accepts a keyboard backlight colour from user space and forwards it to
//  \_SB.KBCD.SCLR (SSDT-KBLT), which writes it to the EC.
//
//  Only one property is accepted: "Color", an OSNumber in 0x000000-0xFFFFFF.
//  Anything else is rejected without touching ACPI.
//

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>

class KBColor : public IOService {
    OSDeclareDefaultStructors(KBColor)
    IOACPIPlatformDevice *dev = nullptr;
    IOLock *lock = nullptr;
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn setProperties(OSObject *properties) override;
};

OSDefineMetaClassAndStructors(KBColor, IOService)

bool KBColor::start(IOService *provider)
{
    if (!IOService::start(provider))
        return false;

    dev = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (dev == nullptr)
        return false;
    lock = IOLockAlloc();
    if (lock == nullptr)
        return false;

    registerService();
    return true;
}

void KBColor::stop(IOService *provider)
{
    if (lock != nullptr) {
        IOLockFree(lock);
        lock = nullptr;
    }
    dev = nullptr;
    IOService::stop(provider);
}

IOReturn KBColor::setProperties(OSObject *properties)
{
    OSDictionary *dict = OSDynamicCast(OSDictionary, properties);
    if (dict == nullptr || dict->getCount() != 1)
        return kIOReturnBadArgument;

    OSNumber *num = OSDynamicCast(OSNumber, dict->getObject("Color"));
    if (num == nullptr)
        return kIOReturnBadArgument;

    unsigned long long color = num->unsigned64BitValue();
    if (color > 0xFFFFFF)
        return kIOReturnBadArgument;

    OSNumber *arg = OSNumber::withNumber(color, 32);
    if (arg == nullptr)
        return kIOReturnNoMemory;

    OSObject *params[1] = { arg };
    IOLockLock(lock);
    IOReturn ret = dev->evaluateObject("SCLR", nullptr, params, 1);
    IOLockUnlock(lock);
    arg->release();

    if (ret == kIOReturnSuccess)
        setProperty("Color", color, 32);
    return ret;
}

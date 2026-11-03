//
//  KBColor.cpp
//  Accepts a keyboard backlight colour from user space and forwards it to
//  \_SB.KBCD.SCLR (SSDT-KBLT), which writes it to the EC.
//
//  Also sets the fan mode through \_SB.KBCD.SFAN / GFAN (SSDT-FANM).
//
//  Exactly one property is accepted per call:
//    "Color"          OSNumber 0x000000-0xFFFFFF
//    "FanMode"        OSNumber 0 = Normal, 1 = Turbo, 2 = Silent
//    "ReadFanMode"    any value; reads the EC and publishes "FanMode",
//                     "CPUFanRPM" and "GPUFanRPM"
//  Anything else is rejected without touching ACPI.
//
//  SSDT-FANM handles Fn+F5 and then sends Notify (KBCD, 0x80); the new mode
//  is published and user space is told with kIOMessageServicePropertyChange.
//

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>

class KBColor : public IOService {
    OSDeclareDefaultStructors(KBColor)
    IOACPIPlatformDevice *dev = nullptr;
    IOLock *lock = nullptr;
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn setProperties(OSObject *properties) override;
    IOReturn message(UInt32 type, IOService *provider, void *argument) override;
private:
    IOReturn setColor(OSNumber *num);
    IOReturn setFanMode(OSNumber *num);
    IOReturn readFanMode();
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

    readFanMode();
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

    if (dict->getObject("ReadFanMode") != nullptr)
        return readFanMode();

    OSNumber *num = OSDynamicCast(OSNumber, dict->getObject("FanMode"));
    if (num != nullptr)
        return setFanMode(num);

    num = OSDynamicCast(OSNumber, dict->getObject("Color"));
    if (num == nullptr)
        return kIOReturnBadArgument;
    return setColor(num);
}

IOReturn KBColor::setColor(OSNumber *num)
{
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

IOReturn KBColor::setFanMode(OSNumber *num)
{
    unsigned long long mode = num->unsigned64BitValue();
    if (mode > 2)
        return kIOReturnBadArgument;

    OSNumber *arg = OSNumber::withNumber(mode, 32);
    if (arg == nullptr)
        return kIOReturnNoMemory;

    OSObject *params[1] = { arg };
    UInt32 result = 1;
    IOLockLock(lock);
    IOReturn ret = dev->evaluateInteger("SFAN", &result, params, 1);
    IOLockUnlock(lock);
    arg->release();

    if (ret != kIOReturnSuccess)
        return ret;
    if (result != 0)
        return kIOReturnNotReady;
    setProperty("FanMode", mode, 32);
    return kIOReturnSuccess;
}

IOReturn KBColor::message(UInt32 type, IOService *provider, void *argument)
{
    if (type == kIOACPIMessageDeviceNotification && provider == dev && argument != nullptr &&
        *static_cast<UInt32 *>(argument) == 0x80) {
        if (readFanMode() == kIOReturnSuccess)
            messageClients(kIOMessageServicePropertyChange);
        return kIOReturnSuccess;
    }
    return IOService::message(type, provider, argument);
}

// The app asks for a fresh read before showing its menu and while it is open.
IOReturn KBColor::readFanMode()
{
    UInt32 mode = 0xFF, cpu = 0, gpu = 0;
    OSNumber *fan0 = OSNumber::withNumber(0ULL, 32);
    OSNumber *fan1 = OSNumber::withNumber(1ULL, 32);
    if (fan0 == nullptr || fan1 == nullptr) {
        OSSafeReleaseNULL(fan0);
        OSSafeReleaseNULL(fan1);
        return kIOReturnNoMemory;
    }
    OSObject *p0[1] = { fan0 }, *p1[1] = { fan1 };

    IOLockLock(lock);
    IOReturn ret = dev->evaluateInteger("GFAN", &mode);
    if (ret == kIOReturnSuccess && dev->evaluateInteger("GRPM", &cpu, p0, 1) == kIOReturnSuccess &&
        dev->evaluateInteger("GRPM", &gpu, p1, 1) == kIOReturnSuccess) {
        setProperty("CPUFanRPM", cpu, 32);
        setProperty("GPUFanRPM", gpu, 32);
    }
    IOLockUnlock(lock);
    fan0->release();
    fan1->release();

    if (ret != kIOReturnSuccess)
        return ret;
    if (mode > 2) {
        removeProperty("FanMode");
        return kIOReturnNotReady;
    }
    setProperty("FanMode", mode, 32);
    return kIOReturnSuccess;
}

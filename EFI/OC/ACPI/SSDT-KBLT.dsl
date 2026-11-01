/*
 * FX506LU keyboard lighting bridge.
 * The DSDT declares the lighting registers in EC0's memory-mapped RAM but no method uses them:
 *   ERAM (0xFE708300) +0xC6 KBBL  brightness level
 *   ERM2 (0xFE708B00) +0x22 KBSP  effect speed
 *                     +0x24 KBLT, +0x25 KBLM  (unknown, exposed for diagnostics)
 *                     +0x28 KBSC  24-bit colour
 *                     +0x2B KBBS  (unknown)
 *                     +0x2C KBMC  effect mode
 * Device FXKB is matched by FX506Lights.kext; ATKD.SKBV lets AsusSMC drive brightness natively.
 */
DefinitionBlock ("", "SSDT", 2, "FX506", "KBLT", 0x00001000)
{
    External (_SB_.ATKD, DeviceObj)
    External (_SB_.PCI0.LPCB.EC0_.KBBL, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.KBSC, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.KBMC, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.KBSP, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.KBBS, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.KBLT, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.KBLM, FieldUnitObj)

    Scope (\_SB)
    {
        Device (FXKB)
        {
            Name (_HID, "FXKB0001")
            Name (KBMX, 0x03)   // highest brightness level, settable from the app

            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin")) { Return (0x0F) }
                Return (Zero)
            }

            // index order shared with the kext/app: KBBL, KBSC, KBMC, KBSP, KBBS, KBLT, KBLM
            Method (RDAL, 0, Serialized)
            {
                Local0 = Package (0x07) {}
                Local0 [Zero] = \_SB.PCI0.LPCB.EC0.KBBL
                Local0 [One] = \_SB.PCI0.LPCB.EC0.KBSC
                Local0 [0x02] = \_SB.PCI0.LPCB.EC0.KBMC
                Local0 [0x03] = \_SB.PCI0.LPCB.EC0.KBSP
                Local0 [0x04] = \_SB.PCI0.LPCB.EC0.KBBS
                Local0 [0x05] = \_SB.PCI0.LPCB.EC0.KBLT
                Local0 [0x06] = \_SB.PCI0.LPCB.EC0.KBLM
                Return (Local0)
            }

            Method (WREG, 2, Serialized)
            {
                Switch (ToInteger (Arg0))
                {
                    Case (Zero) { \_SB.PCI0.LPCB.EC0.KBBL = Arg1 }
                    Case (One) { \_SB.PCI0.LPCB.EC0.KBSC = Arg1 }
                    Case (0x02) { \_SB.PCI0.LPCB.EC0.KBMC = Arg1 }
                    Case (0x03) { \_SB.PCI0.LPCB.EC0.KBSP = Arg1 }
                    Case (0x04) { \_SB.PCI0.LPCB.EC0.KBBS = Arg1 }
                    Case (0x05) { \_SB.PCI0.LPCB.EC0.KBLT = Arg1 }
                    Case (0x06) { \_SB.PCI0.LPCB.EC0.KBLM = Arg1 }
                    Default { Return (One) }
                }
                Return (Zero)
            }

            Method (SMAX, 1, NotSerialized)
            {
                KBMX = Arg0
            }
        }
    }

    Scope (\_SB.ATKD)
    {
        // AsusSMC keyboard backlight hook: scale 0-15 to 0-KBMX, clamp anything larger
        Method (SKBV, 1, Serialized)
        {
            If (_OSI ("Darwin"))
            {
                Local1 = \_SB.FXKB.KBMX
                Local0 = (((ToInteger (Arg0) * Local1) + 0x07) / 0x0F)
                If ((Local0 > Local1)) { Local0 = Local1 }
                \_SB.PCI0.LPCB.EC0.KBBL = Local0
            }
        }
    }
}

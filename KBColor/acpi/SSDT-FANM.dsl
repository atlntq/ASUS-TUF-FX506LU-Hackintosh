/*
 * SSDT-FANM: fan mode (Silent / Normal / Turbo) for ASUS TUF FX506LU.
 *
 * The WMI fan boost call (DEVS 0x00110018 -> SFBM) is empty in this DSDT.
 * The mode lives in EC RAM instead:
 *   ERAM (0xFE708300) + 0x06   EC0.FNGM   0 = Normal, 1 = Turbo, 2 = Silent
 * The EC applies a new FNGM by itself. SFAN only writes it: EC0._QDD, which
 * updates the Windows side (DPTF ODV0, NVIDIA Dynamic Boost), is not called
 * because it notifies DPTF's IETM, which does not exist on macOS; the
 * AE_NOT_FOUND aborted SFAN and the _QB5 that called it.
 *
 * Fn+F5 does not change the mode itself: the EC raises query 0xB5, whose
 * _QB5 queues ATKD event 0xAE for Armoury Crate. That queue is shared with
 * AsusSMC, so on macOS _QB5 is replaced instead (needs the config.plist
 * rename EC0._QB5 -> XQB5): it steps Normal -> Turbo -> Silent -> Normal and
 * sends Notify (KBCD, 0x80) so KBColor.kext can tell the app.
 *
 * Fan speed (from the DSTS 0x00110013 / 0x00110014 handlers):
 *   RPM = 0x20E6DA / EC0.FRMS (CPU fan), 0x20E6DA / EC0.FRS2 (GPU fan)
 *
 * The methods are added to \_SB.KBCD (SSDT-KBLT), so SSDT-FANM must load
 * after SSDT-KBLT. KBColor.kext forwards its "FanMode" property here.
 */
DefinitionBlock ("", "SSDT", 2, "FX506", "FANM", 0x00001000)
{
    External (_SB_.KBCD, DeviceObj)
    External (_SB_.PCI0.LPCB.EC0_, DeviceObj)
    External (_SB_.PCI0.LPCB.EC0_.ECOK, IntObj)
    External (_SB_.PCI0.LPCB.EC0_.MUT0, MutexObj)
    External (_SB_.PCI0.LPCB.EC0_.FNGM, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.XQB5, MethodObj)
    External (_SB_.PCI0.LPCB.EC0_.FRMS, FieldUnitObj)
    External (_SB_.PCI0.LPCB.EC0_.FRS2, FieldUnitObj)

    Scope (\_SB.PCI0.LPCB.EC0)
    {
        // Fn+F5
        Method (_QB5, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Local0 = \_SB.KBCD.GFAN ()
                If ((Local0 > 0x02))
                {
                    Return (Zero)
                }

                Local0++
                If ((Local0 > 0x02))
                {
                    Local0 = Zero
                }

                \_SB.KBCD.SFAN (Local0)
                Notify (\_SB.KBCD, 0x80)
            }
            Else
            {
                XQB5 ()
            }

            Return (Zero)
        }
    }

    Scope (\_SB.KBCD)
    {
        // Returns 0 = Normal, 1 = Turbo, 2 = Silent, 0xFF if the EC is not ready.
        Method (GFAN, 0, Serialized)
        {
            If (!\_SB.PCI0.LPCB.EC0.ECOK)
            {
                Return (0xFF)
            }

            Acquire (\_SB.PCI0.LPCB.EC0.MUT0, 0x1000)
            Local0 = \_SB.PCI0.LPCB.EC0.FNGM
            Release (\_SB.PCI0.LPCB.EC0.MUT0)
            Return (Local0)
        }

        // Arg0: 0 = Normal, 1 = Turbo, 2 = Silent. Returns 0 on success.
        Method (SFAN, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            If ((Local0 > 0x02))
            {
                Return (One)
            }

            If (!\_SB.PCI0.LPCB.EC0.ECOK)
            {
                Return (One)
            }

            Acquire (\_SB.PCI0.LPCB.EC0.MUT0, 0x1000)
            \_SB.PCI0.LPCB.EC0.FNGM = Local0
            Release (\_SB.PCI0.LPCB.EC0.MUT0)
            Return (Zero)
        }

        // Arg0: 0 = CPU fan, 1 = GPU fan. Returns RPM, 0 if stopped.
        Method (GRPM, 1, Serialized)
        {
            If (!\_SB.PCI0.LPCB.EC0.ECOK)
            {
                Return (Zero)
            }

            Acquire (\_SB.PCI0.LPCB.EC0.MUT0, 0x1000)
            If ((ToInteger (Arg0) == Zero))
            {
                Local0 = \_SB.PCI0.LPCB.EC0.FRMS
            }
            Else
            {
                Local0 = \_SB.PCI0.LPCB.EC0.FRS2
            }

            Release (\_SB.PCI0.LPCB.EC0.MUT0)
            If ((Local0 == Zero))
            {
                Return (Zero)
            }

            Return ((0x0020E6DA / Local0))
        }
    }
}

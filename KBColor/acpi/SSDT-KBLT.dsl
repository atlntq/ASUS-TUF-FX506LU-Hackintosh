/*
 * SSDT-KBLT: keyboard backlight brightness for ASUS TUF FX506LU.
 *
 * AsusSMC calls \_SB.ATKD.SKBV(level) with level 0-255 (the macOS keyboard
 * brightness value 0x0-0xFFB divided by 16), for Fn+Up/Down and the
 * Control Center slider.
 *
 * EC RAM layout, found by comparing ERM2 snapshots after changing the
 * setting in Armoury Crate:
 *   ERM2+0x24        brightness level, 0 = off ... 3 = max (DSDT EC0.KBLT)
 *   ERM2+0x2B..0x2D  static colour R, G, B
 *
 * The EC only has 3 brightness levels, so in-between levels are made by
 * keeping the level at 3 and scaling the colour. The colour chosen in
 * Windows is read once and normalised so its brightest component is 0xFF;
 * that keeps the hue even if the EC still holds a dimmed colour from the
 * previous session. Only ERM2+0x24 and ERM2+0x2B..0x2D are written.
 *
 * \_SB.KBCD (KBCD0001) is matched by KBColor.kext, which forwards a colour
 * from the `kbcolor` command line tool to \_SB.ATKD.SKBC (0xRRGGBB).
 */
DefinitionBlock ("", "SSDT", 2, "FX506", "KBLT", 0x00004000)
{
    External (_SB_.ATKD, DeviceObj)
    External (_SB_.PCI0.LPCB.EC0_.KBLT, FieldUnitObj)

    Scope (\_SB.ATKD)
    {
        OperationRegion (KBCR, SystemMemory, 0xFE708B2B, 0x03)
        Field (KBCR, ByteAcc, NoLock, Preserve)
        {
            KCLR,   8,
            KCLG,   8,
            KCLB,   8
        }

        Name (BINI, Zero)
        Name (BASR, 0xFF)
        Name (BASG, 0xFF)
        Name (BASB, 0xFF)
        Name (KLVL, 0xFF)

        // Read the current colour once and normalise it to full intensity.
        Method (KBBC, 0, Serialized)
        {
            Local1 = KCLR
            Local2 = KCLG
            Local3 = KCLB
            Local4 = Local1
            If ((Local2 > Local4))
            {
                Local4 = Local2
            }

            If ((Local3 > Local4))
            {
                Local4 = Local3
            }

            If ((Local4 == Zero))
            {
                // colour was black: fall back to white
                Local1 = 0xFF
                Local2 = 0xFF
                Local3 = 0xFF
                Local4 = 0xFF
            }

            BASR = (((Local1 * 0xFF) + (Local4 >> One)) / Local4)
            BASG = (((Local2 * 0xFF) + (Local4 >> One)) / Local4)
            BASB = (((Local3 * 0xFF) + (Local4 >> One)) / Local4)
            BINI = One
        }

        // Write the base colour scaled to level KLVL and turn the light on.
        Method (KBAP, 0, Serialized)
        {
            KCLR = (((BASR * KLVL) + 0x7F) / 0xFF)
            KCLG = (((BASG * KLVL) + 0x7F) / 0xFF)
            KCLB = (((BASB * KLVL) + 0x7F) / 0xFF)
            \_SB.PCI0.LPCB.EC0.KBLT = 0x03
        }

        // Set a new base colour 0xRRGGBB; applied at the current level.
        Method (SKBC, 1, Serialized)
        {
            Local0 = ToInteger (Arg0)
            BASR = ((Local0 >> 0x10) & 0xFF)
            BASG = ((Local0 >> 0x08) & 0xFF)
            BASB = (Local0 & 0xFF)
            BINI = One
            If ((KLVL != Zero))
            {
                KBAP ()
            }

            Return (Zero)
        }

        Method (SKBV, 1, Serialized)
        {
            If (_OSI ("Darwin"))
            {
                If ((BINI == Zero))
                {
                    KBBC ()
                }

                Local0 = ToInteger (Arg0)
                If ((Local0 > 0xFF))
                {
                    Local0 = 0xFF
                }

                KLVL = Local0
                If ((Local0 == Zero))
                {
                    \_SB.PCI0.LPCB.EC0.KBLT = Zero
                    Return (Zero)
                }

                KBAP ()
            }

            Return (Zero)
        }
    }

    Device (\_SB.KBCD)
    {
        Name (_HID, "KBCD0001")

        Method (_STA, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (0x0F)
            }

            Return (Zero)
        }

        // Called by KBColor.kext with 0xRRGGBB.
        Method (SCLR, 1, Serialized)
        {
            Return (\_SB.ATKD.SKBC (Arg0))
        }
    }
}

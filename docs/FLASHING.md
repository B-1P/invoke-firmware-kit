# Flashing the speaker (Windows)

This uses Harman's own recovery tool and USB driver, which ship inside the
OTA2 package. You need the `Invoke-flash` folder produced by `build.sh`.

## 1. Copy the flash folder to Windows

If you built in WSL, copy `Invoke-flash` to a normal Windows folder, such as
your Desktop. `build.sh` prints its Windows path; you can also open it with
`explorer.exe out` from the kit folder.

## 2. Install the USB driver (once per PC)

Harman's driver is from 2014 and isn't signed for current Windows, so Windows
has to be started once with driver signature checks turned off.

1. Hold **Shift** and click **Restart** (Start → Power).
2. Choose **Troubleshoot → Advanced options → Startup Settings → Restart**.
3. When the list appears, press **7** for *Disable driver signature
   enforcement*. Windows starts normally; the setting lasts until the next
   restart.
4. Put the speaker in flashing mode (step 3 below) with USB connected.
5. Open **Device Manager**. Find the unknown device named like `BG2CD`,
   right-click → **Update driver → Browse my computer for drivers**, choose
   the `Mrvl_WinUSB_Driver_040114` folder inside `Invoke-flash`, and confirm
   the warning about an unsigned driver.

After that, the speaker shows up as a Marvell device whenever it's in flashing
mode.

## 3. Flashing mode

1. Unplug the speaker's power. Connect its USB port to the PC.
2. With a paper clip, **press and hold the reset pinhole**, then plug the power
   back in while still holding it.
3. Still holding reset, **press the mic-mute button 4 times within 5
   seconds**. The top light briefly turns yellow (it can be faint).

## 4. Flash

1. Unplug the speaker's power again.
2. In `Invoke-flash\OTA2`, double-click **`run.bat`**. A console window
   opens. Allow network access if Windows asks.
3. Enter flashing mode (section 3).
4. Keep holding reset until the **U-Boot** screen appears in the PuTTY
   window, then let go.
5. In PuTTY, type **`l2nand 83`** and press Enter. (The first character is a
   lowercase L.)
6. Wait for **`Congratulations! U2nand succeed!`**. It takes a few minutes.
   **Don't unplug anything while it's writing.**
7. Unplug USB and power, wait 10 seconds, and plug the power back in. The
   speaker plays its start-up sound.

## Troubleshooting

- **The U-Boot screen never appears:** unplug the power, wait 10 seconds and
  repeat section 3 with `run.bat` already open. Make sure the driver from
  step 2 is installed.
- **`CRC verify failed` during flashing:** the image is damaged or incomplete.
  Rebuild it, copy the folder again and retry. Nothing is written for a
  partition that fails its check, but the speaker may not start until a
  flash completes; flash again (custom or stock).
- **The speaker doesn't appear on your network:** check the Wi-Fi name and
  password you entered with `--wifi` (2.4 GHz networks are the safest bet),
  then rebuild and reflash.
- **Going back to stock:** flash the untouched OTA2 folder from Harman's zip
  the same way.

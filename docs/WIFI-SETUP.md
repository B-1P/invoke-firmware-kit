# Wi-Fi setup for the Harman Kardon Invoke (custom firmware)

The Harman Kardon Invoke was set up through the Cortana app. That app and
its servers are gone, so a reset or new Invoke has no way to learn your
Wi-Fi. This add-on for the community custom firmware gives the speaker its
own setup page instead, much like many smart plugs and cameras have.

**In short:** if the speaker can't get onto Wi-Fi, it creates its own Wi-Fi
network called **`Invoke-Setup-XXXX`**. Connect your phone to it, choose your
home network, type the password, and you're done.

---

## Setting up Wi-Fi (first time, new router, or a changed password)

1. **Plug the speaker in and wait about 2 minutes.**
   If it can't reach a known Wi-Fi network within about a minute of starting,
   it switches to setup mode.

2. **On your phone, tablet or laptop, open the Wi-Fi settings** and join the
   network **`Invoke-Setup-XXXX`**. XXXX is four letters/digits that differ
   from speaker to speaker. The network has no password.

3. **A "Sign in to network" page opens by itself** (on iPhone it slides up,
   on Android tap the "Sign in to Wi-Fi network" notification).
   If nothing appears after about 10 seconds, open a web browser and go to
   **http://192.168.4.1**

4. **Pick your home network from the list and type its password.**
   - Hidden network? Choose *Other / hidden network* and type its exact name.
   - Network without a password? Leave the password field empty.
   - Tap **Connect**.

5. **Wait about a minute.**
   - **It worked:** `Invoke-Setup-XXXX` disappears and your phone goes back to
     your normal Wi-Fi. The speaker is now on your network. For example, it
     appears as an AirPlay speaker on iPhones and Macs.
   - **It didn't work:** `Invoke-Setup-XXXX` comes back after about two
     minutes. Join it again: the page now explains what went wrong (wrong
     password, network not found, ...). Fix it and press Connect again.

The speaker remembers the network, including after unplugging or reboots.

## When does setup mode start?

- At startup, when no Wi-Fi network is saved, or the saved one doesn't
  connect within about a minute (wrong password, router replaced, moved
  house).
- When you force it (see below).

If your router was just off for a moment (for example after a power cut,
when the speaker starts faster than the router), you don't need to do
anything. While in setup mode the speaker re-tries the saved network every
5 minutes, and closes the setup network on its own once that works.

## Forcing setup mode while the old Wi-Fi still works

Use one of these:

- **The power-cycle trick:** plug the speaker in, **wait about 1 minute,
  unplug it**. Do that **twice**, then plug it in a third time and leave it.
  About a minute later `Invoke-Setup-XXXX` appears. If nobody uses it within
  15 minutes, the speaker goes back to its old network.
- **From a computer (SSH):** run `onboarding start`. See "For tinkerers"
  below.

## What works and what doesn't

| Your network                                  | Works? |
|-----------------------------------------------|--------|
| WPA2 or WPA "Personal" (normal home Wi-Fi)     | yes    |
| WPA2/WPA3 mixed ("transition") mode            | yes (uses WPA2) |
| Open network (no password)                    | yes    |
| Hidden network (name not broadcast)           | yes, via *Other / hidden network* |
| 2.4 GHz and 5 GHz                             | yes    |
| WPA3-only                                     | no: switch the router to WPA2/WPA3 mode |
| Enterprise / 802.1X (user name + password)    | no     |
| WEP (very old)                                | no     |
| Hotel/café networks with a login page         | no     |

Wi-Fi passwords are 8 to 63 characters and case-sensitive.

## Is it safe?

- The setup network only exists while the speaker has no working Wi-Fi, or
  for up to 15 minutes when you force it. It disappears after a successful
  setup.
- The setup network is **open** (no password) on purpose. The speaker has
  no screen and no sticker to show a password on, and many owners no longer
  have any paperwork. The downside: for the minute you're using it, someone
  very close by with special tools could in theory read the Wi-Fi password
  you type. If that worries you, do the setup when no strangers are around,
  or give the setup network a password (see *Settings* below).
- The speaker stores your Wi-Fi password in its internal memory
  (`/data/onboarding/wpa_supplicant.conf`), converted into the scrambled key
  form Wi-Fi uses rather than as plain text. Anyone who can log in to the
  speaker can still use that key to join your network, so treat the speaker
  like any other device on your Wi-Fi.
- On the setup network, the speaker's normal services (such as SSH, if your
  firmware has it) can be reached. Nothing extra is exposed.

## Troubleshooting

| Problem | What to try |
|---|---|
| `Invoke-Setup-XXXX` never appears | Wait 2–3 minutes after plugging in. If the speaker is already on a working Wi-Fi, setup mode won't start by itself; use the power-cycle trick. If someone has SSH access, `onboarding status` and `onboarding log` show why (including the Wi-Fi driver's messages). |
| The page doesn't open by itself | Open a browser and go to **http://192.168.4.1** (type `http://`, not `https://`). Turn off mobile data or a VPN if your phone keeps leaving the setup network. |
| My phone says "No internet" and switches away | That's expected, because the setup network has no internet. Choose "Stay connected" / "Use without internet". |
| My network isn't listed | Tap *Scan again*. Move the speaker closer to the router. Or type the name under *Other / hidden network*. |
| "Password was not accepted" | Check upper/lower case and similar-looking characters (0/O, l/1). |
| Joined, but the speaker isn't found afterwards | Give it a minute. Check your router's device list for a device called `harman` or `LibreSync`. Restarting the speaker (unplug/plug) does no harm. |
| Joined (the page said it worked), but AirPlay and SSH can't find the speaker | Your router probably isolates devices on that network, so nothing else on it can reach the speaker. This is common on 5 GHz, guest and "IoT" networks (look for "AP isolation" or "client isolation" in the router settings). Turn isolation off, or run setup again and choose your main 2.4 GHz network. The setup log in `/data/onboarding/onboarding.log` survives unplugging, so `onboarding log` still shows what happened. |

## Settings (optional)

You can change a few things by creating the file
`/data/onboarding/onboarding.conf` on the speaker (needs SSH). Put in only the
lines you want to change, for example:

```
WIFI_COUNTRY=DE            # your country, for the right Wi-Fi channels (default: US)
AP_PASSPHRASE=mysecret123  # give the setup network a password (8-63 characters)
AP_CHANNEL=11              # channel of the setup network (1, 6 or 11)
BOOT_TIMEOUT=90            # wait longer for your Wi-Fi at startup
RAPID_BOOTS=0              # switch off the power-cycle trick
LOST_TIMEOUT=600           # also open setup mode if Wi-Fi is lost for 10 minutes
```

All settings and their defaults are in `/usr/share/onboarding/onboarding.conf`.

## For tinkerers: commands (over SSH, as root)

```
onboarding status            # what's going on
onboarding start             # open the setup network now (usually keeps the current Wi-Fi)
onboarding stop              # close it again, back to the normal Wi-Fi
onboarding join "My WiFi" "password"   # change network without the web page
onboarding scan              # list nearby networks
onboarding forget            # delete the saved network (applies at next reboot)
onboarding force-next-boot   # open the setup network at the next startup
onboarding log               # show what happened (kept in /data/onboarding/, so it survives
                             # unplugging; includes the Wi-Fi driver's messages if the setup network fails)
```

Over the setup network the speaker is at **192.168.4.1**, so you can also
SSH to it there.

---

*No warranty. The Invoke is a discontinued product and this is community
firmware. You use it at your own risk.*

# Harman's control bus: LED ring and buttons

The speaker's own services talk to each other over a WAMP message bus (the
`bonefish` router). From another machine on your network you can use it to
play LED animations and to receive button and touch events, for example to
connect the speaker to Home Assistant.

These are notes from testing on one speaker running a kit build. Anything not
listed as confirmed hasn't been tried.

## Access

The bus is **closed by default**. Build with `--control-bus` to open it to
your network.

> The bus has **no authentication**. With it open, any device on your network
> can control the speaker's LEDs and listen to its buttons. Only open it on a
> network you trust.

| | |
|---|---|
| WebSocket | port **9998**, subprotocol `wamp.2.json` |
| Raw TCP | port 9999, MessagePack only (JSON is refused) |
| Realm | `default` |

The two scripts in `tools/` need only Python 3's standard library:

```sh
# Play an LED animation
python3 tools/wamp_call.py <speaker-ip> com.harman.ledAnimate '["L_312_d_shorttap"]'

# Print button, touch and volume events for 60 seconds
python3 tools/wamp_listen.py <speaker-ip> 60
```

## LED ring

Call `com.harman.ledAnimate` with the name of an animation file from
`/usr/share/lights/` (without `.bin`). Confirmed working for the first four;
the call returns an empty result.

| Animation | Shown by the stock firmware for |
|---|---|
| `L_312_d_shorttap` | a tap on the top |
| `L_303_d_wificonnected` | Wi-Fi connected |
| `L_311_d_pluggedin` | power connected |
| `L_404_o_oobesuccess` | setup finished |
| `L_108_c_error` | an error |
| `L_302_d_wifisetup` | Wi-Fi setup |
| `L_309_d_pinreset` | reset |
| `L_403_o_firstupdate` | first update |

Only these eight animations ship in the final firmware. Custom animations
would need the `.bin` format decoded (each frame is 39 bytes) and a writable
place to put them; that hasn't been done.

## Buttons and touch

Subscribe to `com.harman.test.inputEvent`. Each event's arguments are
`[name, value]`:

| Control | Event | Confirmed |
|---|---|---|
| Tap on the top | `["action", "0"]` | yes |
| Volume ring, up | `["volumeup", "N"]` | yes |
| Volume ring, down | `["volumedown", "N"]` | yes |
| Bluetooth button | `["bluetooth", "0"]` | yes |
| Long press on the top | `["action-long", ...]` | no event seen |
| Mic-mute button | `["micmute", ...]` | no event seen |

`N` is how many volume steps that tick of the ring moved. One turn of the
ring sends a quick burst of these.

After each volume step, `com.harman.volumeChanged` reports the new level as
`["music", 0-100]`, which is handy as an absolute dimmer value.

The firmware's input handler also knows `bluetooth-long`, `micmute-long`,
`reset` and `reset-long`. In testing, the long press on the top and the
mic-mute button produced no bus events. The firmware contains the message
"Reaction on short press of micmute button is disabled".

**The speaker still reacts to these controls itself.** The ring changes the
speaker's volume, and the Bluetooth button does its normal job. Other
listeners just receive a copy of each event; they can't block it. The tap is
the cleanest control to repurpose.

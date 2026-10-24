# Microphones and voice control: findings

Notes from testing on one speaker running a kit build. Nothing here is part
of the kit yet.

## What's on the speaker

- **The wake-word engine is gone.** "Hey Cortana" was detected on the
  speaker by Microsoft's Cortana app, which ran from `/data/cortana` and was
  removed by Harman's final update. Neither the final firmware nor Harman's
  GPL source release contains it; it is also proprietary, so it isn't an
  option for this project.
- **The audio DSP still processes the microphones.** It does the far-field
  front end (closed firmware loaded from `/usr/share/dsp/dsp-img.ldr`) and
  passes Linux a cleaned-up signal. It has no keyword-detection event.
- Leftovers in the firmware: Cortana event names in `audio-ui`, the LED
  names for listening/thinking/speaking (the animation files themselves
  aren't shipped), and an unused music-player plugin.

## The microphone works (confirmed)

```sh
arecord -D mic -d 8 -r 16000 -c 1 -f S16_LE -t wav /tmp/test.wav
```

`mic` is the left channel of the DSP output, labelled for speech recognition
in `/etc/asound-product.conf` (`mic_call`, the right channel, is for calls).
A test recording at 16 kHz mono showed speech/claps around -13 to -19 dBFS
over a background around -58 dBFS, so the microphone is live and not muted
by the DSP. The capture device is shared (`dsnoop`), so recording doesn't
block anything else. Clarity across a room hasn't been assessed.

## Options for voice control

The aim is to avoid streaming audio continuously off the speaker.

1. **Tap to talk.** A tap on the top publishes `["action", "0"]` on the
   control bus (see CONTROL-BUS.md). A script on the speaker could record a
   few seconds only after a tap, send them to Home Assistant, show an LED
   animation while listening, and play the spoken reply through `aplay -D
   voice`. No always-on audio processing at all.
2. **Wake word on the speaker.** Detect the wake word locally, as Cortana
   did, and only send audio after it's heard. Candidate: microWakeWord
   (Apache-2.0 models, designed for much smaller chips). Needs an inference
   runtime built for the speaker; a statically linked build would avoid the
   speaker's old glibc. The microphone is processed continuously, but only
   on the speaker.
3. **Stream to Home Assistant** (Wyoming satellite with openWakeWord on the
   server). Simplest, but audio leaves the speaker all the time.

Home Assistant can do speech-to-text and text-to-speech locally, so none of
these needs the cloud.

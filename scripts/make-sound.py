#!/usr/bin/env python3
"""Generate Resources/alarm.wav: three two-tone beeps then a pause, about 1.2 s, looped by the app."""
import math
import struct
import sys
import wave

RATE = 44100


def tone(freq, seconds, volume=0.5):
    n = int(RATE * seconds)
    fade = int(RATE * 0.005)
    for i in range(n):
        envelope = min(1.0, i / fade, (n - i) / fade)
        sample = math.sin(2 * math.pi * freq * i / RATE) + 0.3 * math.sin(4 * math.pi * freq * i / RATE)
        yield volume * envelope * sample / 1.3


def silence(seconds):
    return [0.0] * int(RATE * seconds)


samples = []
for _ in range(3):
    samples += list(tone(880, 0.09)) + list(tone(1320, 0.09)) + silence(0.06)
samples += silence(0.48)

out = sys.argv[1] if len(sys.argv) > 1 else "Resources/alarm.wav"
with wave.open(out, "wb") as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(RATE)
    f.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))
print(f"wrote {out}")

import wave
import struct
import math

rate = 48000
dur = 3
frames = bytearray()
for i in range(rate * dur):
    left = int(8192 * math.sin(2 * math.pi * 440 * i / rate))
    right = int(8192 * math.sin(2 * math.pi * 880 * i / rate))
    frames += struct.pack('<hh', left, right)

w = wave.open('/tmp/tone-stereo.wav', 'w')
w.setnchannels(2)
w.setsampwidth(2)
w.setframerate(rate)
w.writeframes(bytes(frames))
w.close()
print('written /tmp/tone-stereo.wav')

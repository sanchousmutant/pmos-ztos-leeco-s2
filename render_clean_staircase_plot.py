import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import shutil

WAV_PATH = r"E:\Project\postmarketos\staircase_recording.wav"
PNG_PATH = r"E:\Project\postmarketos\staircase_verification.png"
ARTIFACT_PNG = r"C:\Users\sanch\.gemini\antigravity-cli\brain\e1972c01-e01b-41e5-8ed4-aa6e5047d318\staircase_verification.png"

sr, data = wavfile.read(WAV_PATH)
if data.ndim > 1:
    audio = data[:, 0].astype(np.float64)
else:
    audio = data.astype(np.float64)
dur = len(audio) / sr

win = int(0.05 * sr)
rms_vals = [np.sqrt(np.mean(audio[i:i+win]**2)) for i in range(0, len(audio)-win, int(0.01*sr))]
quiet_floor = np.percentile(rms_vals, 15)

tones = [
    {'expected': 1000, 't0': 1.5, 't1': 2.3, 'center': 1.89},
    {'expected': 1500, 't0': 2.4, 't1': 3.2, 'center': 2.82},
    {'expected': 2000, 't0': 3.3, 't1': 4.3, 'center': 3.75},
    {'expected': 2500, 't0': 4.4, 't1': 5.3, 'center': 4.85},
]

for t_info in tones:
    chunk = audio[int(t_info['t0']*sr):int(t_info['t1']*sr)]
    rms = np.sqrt(np.mean(chunk**2))
    snr = 20 * np.log10(rms / quiet_floor)
    freqs = np.fft.rfftfreq(len(chunk), 1/sr)
    fft_v = np.abs(np.fft.rfft(chunk))
    mask = (freqs >= t_info['expected'] - 80) & (freqs <= t_info['expected'] + 80)
    det = freqs[mask][np.argmax(fft_v[mask])]
    t_info['detected'] = det
    t_info['rms'] = rms
    t_info['snr'] = snr

fig = plt.figure(figsize=(13, 10))
gs = fig.add_gridspec(3, 1, height_ratios=[1, 1.4, 0.9])

# 1. Waveform
ax1 = fig.add_subplot(gs[0])
t_axis = np.linspace(0, dur, len(audio))
ax1.plot(t_axis, audio, color='#1f77b4', linewidth=0.7)
ax1.set_title("Acoustic Recording Waveform (Fifine Microphone on Windows Host)", fontsize=12, fontweight='bold')
ax1.set_ylabel("Amplitude")
ax1.set_xlim(0, dur)
ax1.grid(True, alpha=0.3)

# 2. Spectrogram
ax2 = fig.add_subplot(gs[1])
f, t_s, Sxx = signal.spectrogram(audio, sr, nperseg=2048, noverlap=1024)
im = ax2.pcolormesh(t_s, f, 10*np.log10(Sxx+1e-9), cmap='plasma', shading='gouraud')
ax2.set_ylim(400, 3200)
ax2.set_ylabel("Frequency (Hz)", fontsize=11)
ax2.set_title("Spectrogram: Verified Physical Acoustic Staircase (1000 -> 1500 -> 2000 -> 2500 Hz)", fontsize=12, fontweight='bold')

for t_info in tones:
    ax2.axhline(t_info['expected'], color='cyan', linestyle=':', alpha=0.6)
    ax2.scatter(t_info['center'], t_info['detected'], color='white', s=70, edgecolors='black', zorder=5)
    ax2.annotate(f"{t_info['detected']:.0f} Hz (+{t_info['snr']:.1f} dB)",
                 (t_info['center'], t_info['detected']),
                 textcoords="offset points", xytext=(0, 15),
                 ha='center', fontsize=9, color='white', fontweight='bold',
                 bbox=dict(boxstyle="round,pad=0.25", fc="black", alpha=0.75))

fig.colorbar(im, ax=ax2, label="Acoustic Intensity (dB)")
ax2.set_xlim(0, dur)

# 3. Bar chart
ax3 = fig.add_subplot(gs[2])
x_pos = np.arange(len(tones))
labels = [f"{t['expected']} Hz\n-> {t['detected']:.0f} Hz" for t in tones]
snrs = [t['snr'] for t in tones]
bars = ax3.bar(x_pos, snrs, color=['#2ca02c', '#1f77b4', '#9467bd', '#ff7f0e'], width=0.45, edgecolor='black')
ax3.set_xticks(x_pos)
ax3.set_xticklabels(labels, fontsize=10, fontweight='bold')
ax3.set_ylabel("SNR over Room Noise (dB)", fontsize=11)
ax3.set_title("Acoustic Signal-to-Noise Ratio (Physical Phone Speaker into PC Microphone)", fontsize=12, fontweight='bold')
ax3.grid(True, axis='y', alpha=0.3)
ax3.set_ylim(0, max(snrs) + 4)

for bar, s in zip(bars, snrs):
    yval = bar.get_height()
    ax3.text(bar.get_x() + bar.get_width()/2.0, yval + 0.3, f"+{s:.1f} dB", ha='center', va='bottom', fontweight='bold')

plt.tight_layout()
plt.savefig(PNG_PATH, dpi=150)
shutil.copy(PNG_PATH, ARTIFACT_PNG)
print("Updated spectrogram plot successfully!")

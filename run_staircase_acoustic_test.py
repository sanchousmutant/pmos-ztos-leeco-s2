import subprocess
import time
import shutil
import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

WAV_PATH = r"E:\Project\postmarketos\staircase_recording.wav"
PNG_PATH = r"E:\Project\postmarketos\staircase_verification.png"
ARTIFACT_PNG = r"C:\Users\sanch\.gemini\antigravity-cli\brain\e1972c01-e01b-41e5-8ed4-aa6e5047d318\staircase_verification.png"
SSH_KEY = r"E:\Project\postmarketos\id_rsa"
PHONE_IP = "172.16.42.1"

print("=" * 65)
print("=== ACOUSTIC 4-STEP CHIME VERIFICATION TEST ===")
print("=" * 65)

# Step 1: Start recording
ffmpeg_cmd = [
    "ffmpeg", "-y",
    "-f", "dshow",
    "-i", "audio=Microphone (fifine  Microphone)",
    "-t", "7",
    "-ar", "48000",
    WAV_PATH
]
print("[1/4] Starting 7s recording with Fifine microphone...")
rec_proc = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Give 0.7s to initialize
time.sleep(0.7)

# Step 2: Trigger chime
print("[2/4] Triggering 4-step chime (1000 -> 1500 -> 2000 -> 2500 Hz) on phone...")
ssh_cmd = [
    "ssh", "-i", SSH_KEY,
    f"root@{PHONE_IP}",
    'su - pmos -c "XDG_RUNTIME_DIR=/run/user/1000 pw-play /home/pmos/staircase_chime.wav"'
]
play_proc = subprocess.Popen(ssh_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Wait
print("[3/4] Capturing acoustic output...")
play_out, play_err = play_proc.communicate()
rec_out, rec_err = rec_proc.communicate()

# Step 3: Analyze
print("[4/4] Analyzing acoustic spectrogram...")
sr, data = wavfile.read(WAV_PATH)
if data.ndim > 1:
    audio = data[:, 0].astype(np.float64)
else:
    audio = data.astype(np.float64)

dur = len(audio) / sr

# Spectrogram
f, t, Sxx = signal.spectrogram(audio, sr, nperseg=2048, noverlap=1024)
Sxx_db = 10 * np.log10(Sxx + 1e-9)

# Baseline noise floor (first 0.5s)
base_chunk = audio[:int(0.5*sr)]
base_rms = np.sqrt(np.mean(base_chunk**2))

# Find the 4 tone regions using sliding energy
expected_freqs = [1000, 1500, 2000, 2500]
results = []

for ef in expected_freqs:
    # Bandpass filter around target frequency +/- 50 Hz
    sos = signal.butter(4, [ef - 60, ef + 60], btype='bandpass', fs=sr, output='sos')
    filtered = signal.sosfilt(sos, audio)
    # Envelope
    env = np.abs(signal.hilbert(filtered))
    # Smooth
    win = int(0.2 * sr)
    smoothed = np.convolve(env, np.ones(win)/win, mode='same')
    peak_idx = np.argmax(smoothed)
    peak_time = peak_idx / sr
    peak_rms = smoothed[peak_idx]
    
    # FFT around the peak time (0.5s window)
    w_start = max(0, int((peak_time - 0.25) * sr))
    w_end = min(len(audio), int((peak_time + 0.25) * sr))
    w_chunk = audio[w_start:w_end]
    w_freqs = np.fft.rfftfreq(len(w_chunk), 1/sr)
    w_fft = np.abs(np.fft.rfft(w_chunk))
    
    # Focus around target
    target_mask = (w_freqs >= ef - 100) & (w_freqs <= ef + 100)
    detected_freq = w_freqs[target_mask][np.argmax(w_fft[target_mask])]
    snr = 20 * np.log10(max(peak_rms, 1e-3) / max(base_rms, 1e-3))
    
    results.append({
        'expected': ef,
        'detected': detected_freq,
        'time': peak_time,
        'rms': peak_rms,
        'snr': snr
    })

print("\n--- ACOUSTIC FREQUENCY STEP RESULTS ---")
for r in results:
    status = "PASS" if abs(r['detected'] - r['expected']) < 15 and r['snr'] > 6 else "WEAK"
    print(f"[{status}] Expected {r['expected']:4d} Hz -> Detected {r['detected']:6.1f} Hz @ t={r['time']:4.2f}s (SNR: {r['snr']:4.1f} dB)")

# Plotting
fig = plt.figure(figsize=(13, 11))
gs = fig.add_gridspec(3, 1, height_ratios=[1, 1.5, 1])

# 1. Waveform
ax1 = fig.add_subplot(gs[0])
time_axis = np.linspace(0, dur, len(audio))
ax1.plot(time_axis, audio, color='#1f77b4', linewidth=0.8)
ax1.set_title("Acoustic Recording Waveform (Fifine Microphone on PC)", fontsize=12, fontweight='bold')
ax1.set_ylabel("Amplitude")
ax1.set_xlim(0, dur)
ax1.grid(True, alpha=0.3)

# 2. Spectrogram with frequency markers
ax2 = fig.add_subplot(gs[1])
im = ax2.pcolormesh(t, f, Sxx_db, cmap='plasma', shading='gouraud')
ax2.set_ylim(400, 3200)
ax2.set_ylabel("Frequency (Hz)", fontsize=11)
ax2.set_title("Spectrogram: 4-Step Frequency Staircase (1000 -> 1500 -> 2000 -> 2500 Hz)", fontsize=12, fontweight='bold')
for r in results:
    ax2.axhline(r['expected'], color='cyan', linestyle=':', alpha=0.6)
    ax2.text(0.1, r['expected'] + 50, f"Target {r['expected']} Hz", color='cyan', fontsize=9, fontweight='bold')
    ax2.scatter(r['time'], r['detected'], color='white', s=60, edgecolors='black', zorder=5)
    ax2.annotate(f"{r['detected']:.0f} Hz\n+{r['snr']:.1f} dB",
                 (r['time'], r['detected']),
                 textcoords="offset points", xytext=(0, 15),
                 ha='center', fontsize=9, color='white',
                 bbox=dict(boxstyle="round,pad=0.2", fc="black", alpha=0.7))

fig.colorbar(im, ax=ax2, label="Acoustic Intensity (dB)")
ax2.set_xlim(0, dur)

# 3. Step Detection Summary Bar Chart
ax3 = fig.add_subplot(gs[2])
x_pos = np.arange(len(results))
expected_labels = [f"{r['expected']} Hz" for r in results]
detected_labels = [f"Detected:\n{r['detected']:.1f} Hz\n(+{r['snr']:.1f} dB)" for r in results]
snrs = [max(0, r['snr']) for r in results]

bars = ax3.bar(x_pos, snrs, color=['#2ca02c' if s > 10 else '#ff7f0e' for s in snrs], width=0.5, edgecolor='black')
ax3.set_xticks(x_pos)
ax3.set_xticklabels(detected_labels, fontsize=10)
ax3.set_ylabel("Signal-to-Noise Ratio (dB)", fontsize=11)
ax3.set_title("Detected Acoustic Power per Frequency Step (Physical Phone Speaker)", fontsize=12, fontweight='bold')
ax3.grid(True, axis='y', alpha=0.3)

for bar, s in zip(bars, snrs):
    yval = bar.get_height()
    ax3.text(bar.get_x() + bar.get_width()/2.0, yval + 1, f"{s:.1f} dB", ha='center', va='bottom', fontweight='bold')

plt.tight_layout()
plt.savefig(PNG_PATH, dpi=150)
shutil.copy(PNG_PATH, ARTIFACT_PNG)
print(f"Plot saved to: {PNG_PATH} and artifact")

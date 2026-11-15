import subprocess
import time
import wave
import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

WAV_PATH = r"E:\Project\postmarketos\acoustic_recording.wav"
PNG_PATH = r"E:\Project\postmarketos\acoustic_analysis.png"
SSH_KEY = r"E:\Project\postmarketos\id_rsa"
PHONE_IP = "172.16.42.1"

print("=" * 60)
print("=== STARTING ACOUSTIC MICROPHONE TEST ===")
print("=" * 60)

# Step 1: Start recording on host PC using ffmpeg and Fifine microphone
ffmpeg_cmd = [
    "ffmpeg", "-y",
    "-f", "dshow",
    "-i", "audio=Microphone (fifine  Microphone)",
    "-t", "8",
    "-ar", "48000",
    WAV_PATH
]

print("[1/4] Starting ffmpeg recording on Windows host (8 seconds)...")
rec_proc = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Give ffmpeg 0.6 seconds to initialize DirectShow stream
time.sleep(0.6)

# Step 2: Trigger playback on phone
print("[2/4] Triggering tone playback on LeEco Le 2 via SSH...")
ssh_cmd = [
    "ssh", "-i", SSH_KEY,
    f"root@{PHONE_IP}",
    'su - pmos -c "XDG_RUNTIME_DIR=/run/user/1000 pw-play /home/pmos/mic_verification_test.wav"'
]
play_proc = subprocess.Popen(ssh_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Wait for both processes
print("[3/4] Recording and playing in progress...")
play_out, play_err = play_proc.communicate()
rec_out, rec_err = rec_proc.communicate()

print(f"Playback finished with code {play_proc.returncode}")
print(f"Recording finished with code {rec_proc.returncode}")

# Step 3: Analyze the recorded audio
print("[4/4] Analyzing acoustic recording...")
sr, data = wavfile.read(WAV_PATH)
if data.ndim > 1:
    audio = data[:, 0].astype(np.float64) # Take left/mono channel
else:
    audio = data.astype(np.float64)

dur = len(audio) / sr
print(f"Recorded {dur:.2f} seconds @ {sr} Hz ({len(audio)} samples)")

# Normalization & RMS
max_val = np.max(np.abs(audio))
overall_rms = np.sqrt(np.mean(audio**2))
print(f"Overall Peak Amplitude: {max_val:.0f} / 32767 ({max_val/32768*100:.1f}%)")
print(f"Overall RMS: {overall_rms:.2f}")

# Sliding window RMS (50ms window)
win_size = int(sr * 0.05)
hop_size = int(sr * 0.01)
rms_times = []
rms_values = []
for i in range(0, len(audio) - win_size, hop_size):
    chunk = audio[i:i+win_size]
    rms = np.sqrt(np.mean(chunk**2))
    rms_values.append(rms)
    rms_times.append((i + win_size/2) / sr)

rms_times = np.array(rms_times)
rms_values = np.array(rms_values)

# Find silence floor vs peak sound
baseline_floor = np.percentile(rms_values, 10)
peak_sound = np.max(rms_values)
snr_db = 20 * np.log10(peak_sound / max(baseline_floor, 1e-6))
print(f"Baseline Noise Floor RMS: {baseline_floor:.2f}")
print(f"Peak Sound RMS: {peak_sound:.2f}")
print(f"Signal-to-Noise Ratio (SNR): {snr_db:.1f} dB")

# FFT analysis of active regions
freqs = np.fft.rfftfreq(len(audio), 1 / sr)
spectrum = np.abs(np.fft.rfft(audio))

# Identify dominant frequencies between 200 Hz and 3000 Hz
mask = (freqs >= 200) & (freqs <= 3000)
sub_freqs = freqs[mask]
sub_spec = spectrum[mask]

# Find peaks in spectrum
peak_indices, properties = signal.find_peaks(sub_spec, height=np.max(sub_spec)*0.15, distance=int(100 / (freqs[1]-freqs[0])))
peak_frequencies = sub_freqs[peak_indices]
peak_amplitudes = sub_spec[peak_indices]

# Sort by amplitude
sorted_order = np.argsort(peak_amplitudes)[::-1]
detected_peaks = peak_frequencies[sorted_order][:5]

print("\n--- DETECTED ACOUSTIC FREQUENCIES ---")
for p in detected_peaks:
    print(f"-> Peak at: {p:.1f} Hz")

# Check if expected test frequencies (880 Hz, 1760 Hz, 440 Hz) are present
expected = [440, 880, 1760]
detected_expected = []
for exp in expected:
    diffs = np.abs(peak_frequencies - exp)
    if len(diffs) > 0 and np.min(diffs) < 25:
        match_idx = np.argmin(diffs)
        detected_expected.append((exp, peak_frequencies[match_idx]))

print("\n--- TEST FREQUENCY VERIFICATION ---")
for exp, detected in detected_expected:
    print(f"  [PASS] Expected {exp} Hz -> Detected {detected:.1f} Hz!")

if len(detected_expected) >= 2:
    print("\n>>> VERIFICATION SUCCESSFUL: Physical speaker output acoustic waves confirmed! <<<")
else:
    print(f"\n>>> Detected {len(detected_expected)}/3 expected frequencies. <<<")

# Step 4: Plot visualization
fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(12, 10))
time_axis = np.linspace(0, dur, len(audio))

# 1. Waveform
ax1.plot(time_axis, audio, color='#1f77b4', alpha=0.8, linewidth=0.7)
ax1.set_title("Acoustic Recording Waveform (from Fifine PC Microphone)", fontsize=12, fontweight='bold')
ax1.set_xlabel("Time (seconds)")
ax1.set_ylabel("Amplitude")
ax1.grid(True, alpha=0.3)
ax1.set_xlim(0, dur)

# 2. Spectrogram
f, t, Sxx = signal.spectrogram(audio, sr, nperseg=2048, noverlap=1024)
im = ax2.pcolormesh(t, f, 10 * np.log10(Sxx + 1e-9), cmap='inferno', shading='gouraud')
ax2.set_ylim(0, 3000)
ax2.set_title("Spectrogram (Frequency vs Time) - Look for 880Hz, 1760Hz, 440Hz steps", fontsize=12, fontweight='bold')
ax2.set_ylabel("Frequency (Hz)")
ax2.set_xlabel("Time (seconds)")
fig.colorbar(im, ax=ax2, label="Intensity (dB)")

# 3. RMS Energy over time
ax3.plot(rms_times, rms_values, color='#2ca02c', linewidth=1.5, label="RMS Energy (50ms window)")
ax3.axhline(baseline_floor, color='gray', linestyle='--', label=f"Noise Floor ({baseline_floor:.1f})")
ax3.axhline(peak_sound, color='red', linestyle=':', label=f"Peak Sound ({peak_sound:.1f})")
ax3.set_title(f"Acoustic Power Profile (SNR: {snr_db:.1f} dB)", fontsize=12, fontweight='bold')
ax3.set_xlabel("Time (seconds)")
ax3.set_ylabel("RMS Level")
ax3.legend(loc='upper right')
ax3.grid(True, alpha=0.3)
ax3.set_xlim(0, dur)

plt.tight_layout()
plt.savefig(PNG_PATH, dpi=150)
print(f"\nAnalysis plot saved to: {PNG_PATH}")

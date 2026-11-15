import subprocess
import time
import numpy as np
import scipy.io.wavfile as wavfile
import scipy.signal as signal
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

REF_WAV = r"E:\Project\postmarketos\music_test_ref.wav"
REC_WAV = r"E:\Project\postmarketos\music_recorded.wav"
PNG_PATH = r"E:\Project\postmarketos\music_acoustic_verification.png"
SSH_KEY = r"E:\Project\postmarketos\id_rsa"
PHONE_IP = "172.16.42.1"

print("=" * 65)
print("=== MUSIC ACOUSTIC VERIFICATION TEST (MICROPHONE + PHONE) ===")
print("=" * 65)

# Step 1: Start recording with PC microphone
ffmpeg_cmd = [
    "ffmpeg", "-y",
    "-f", "dshow",
    "-i", "audio=Microphone (fifine  Microphone)",
    "-t", "12",
    "-ar", "48000",
    REC_WAV
]

print("[1/4] Starting 12s microphone recording on Windows host...")
rec_proc = subprocess.Popen(ffmpeg_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Wait 0.8s for ffmpeg to start capturing
time.sleep(0.8)

# Step 2: Trigger playback of the 10s music clip on phone
print("[2/4] Triggering 10s music playback (SoundHelix) on phone speaker...")
ssh_cmd = [
    "ssh", "-i", SSH_KEY,
    f"root@{PHONE_IP}",
    'su - pmos -c "XDG_RUNTIME_DIR=/run/user/1000 pw-play /home/pmos/music_test_10s.wav"'
]
play_proc = subprocess.Popen(ssh_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Wait for completion
print("[3/4] Recording and playback in progress...")
play_out, play_err = play_proc.communicate()
rec_out, rec_err = rec_proc.communicate()

print(f"Phone playback finished (exit code {play_proc.returncode})")
print(f"Host recording finished (exit code {rec_proc.returncode})")

# Step 3: Analysis
print("[4/4] Comparing original reference vs acoustic microphone recording...")

sr_ref, ref_data = wavfile.read(REF_WAV)
if ref_data.ndim > 1:
    ref = ref_data[:, 0].astype(np.float64)
else:
    ref = ref_data.astype(np.float64)

sr_rec, rec_data = wavfile.read(REC_WAV)
if rec_data.ndim > 1:
    rec = rec_data[:, 0].astype(np.float64)
else:
    rec = rec_data.astype(np.float64)

dur_ref = len(ref) / sr_ref
dur_rec = len(rec) / sr_rec
print(f"Reference: {dur_ref:.2f}s @ {sr_ref} Hz")
print(f"Recording: {dur_rec:.2f}s @ {sr_rec} Hz")

# Filter both to midrange/treble 800 - 4000 Hz where phone speaker produces acoustic output
sos = signal.butter(4, [800, 4000], btype='bandpass', fs=48000, output='sos')
ref_filt = signal.sosfilt(sos, ref)
rec_filt = signal.sosfilt(sos, rec)

# Calculate envelopes (Hilbert transform)
env_ref = np.abs(signal.hilbert(ref_filt))
env_rec = np.abs(signal.hilbert(rec_filt))

# Downsample envelopes to 100 Hz for robust acoustic cross-correlation
step = 480
env_ref_ds = env_ref[::step]
env_rec_ds = env_rec[::step]

# Demean
env_ref_ds = (env_ref_ds - np.mean(env_ref_ds)) / (np.std(env_ref_ds) + 1e-9)
env_rec_ds = (env_rec_ds - np.mean(env_rec_ds)) / (np.std(env_rec_ds) + 1e-9)

# Cross-correlation
corr = signal.correlate(env_rec_ds, env_ref_ds, mode='full') / len(env_ref_ds)
lags = signal.correlation_lags(len(env_rec_ds), len(env_ref_ds), mode='full')
lags_sec = lags / (48000 / step)

# Best lag
best_idx = np.argmax(corr)
best_lag = lags_sec[best_idx]
max_corr = corr[best_idx]

rec_rms = np.sqrt(np.mean(rec**2))
rec_peak = np.max(np.abs(rec))

print(f"\n--- ACOUSTIC CORRELATION RESULTS ---")
print(f"Microphone Peak Amplitude: {rec_peak:.0f} / 32767")
print(f"Microphone Overall RMS: {rec_rms:.2f}")
print(f"Acoustic Envelope Correlation: {max_corr:.3f} (Lag: {best_lag:.2f}s)")

# Plot comparison
fig, axes = plt.subplots(3, 1, figsize=(13, 11))

# Plot 1: Reference Audio Spectrogram
f_ref, t_ref, S_ref = signal.spectrogram(ref, sr_ref, nperseg=2048, noverlap=1024)
im1 = axes[0].pcolormesh(t_ref, f_ref, 10 * np.log10(S_ref + 1e-9), cmap='viridis', shading='gouraud')
axes[0].set_ylim(0, 4000)
axes[0].set_title("ORIGINAL MUSIC AUDIO (Reference File on Phone)", fontsize=11, fontweight='bold')
axes[0].set_ylabel("Frequency (Hz)")
axes[0].set_xlabel("Time (seconds)")
fig.colorbar(im1, ax=axes[0], label="dB")

# Plot 2: Recorded Audio Spectrogram
f_rec, t_rec, S_rec = signal.spectrogram(rec, sr_rec, nperseg=2048, noverlap=1024)
im2 = axes[1].pcolormesh(t_rec, f_rec, 10 * np.log10(S_rec + 1e-9), cmap='inferno', shading='gouraud')
axes[1].set_ylim(0, 4000)
axes[1].set_title(f"ACOUSTIC RECORDING FROM PC MICROPHONE (Peak: {rec_peak:.0f}, Correlation: {max_corr:.2f})", fontsize=11, fontweight='bold')
axes[1].set_ylabel("Frequency (Hz)")
axes[1].set_xlabel("Time (seconds)")
fig.colorbar(im2, ax=axes[1], label="dB")

# Plot 3: Acoustic Envelope Alignment
t_rec_axis = np.linspace(0, dur_rec, len(env_rec_ds))
t_ref_aligned = np.linspace(best_lag, best_lag + dur_ref, len(env_ref_ds))

axes[2].plot(t_rec_axis, env_rec_ds, color='#d62728', alpha=0.8, label="PC Microphone Acoustic Envelope")
axes[2].plot(t_ref_aligned, env_ref_ds, color='#1f77b4', linestyle='--', alpha=0.9, label=f"Original Audio Envelope (Shifted {best_lag:.2f}s)")
axes[2].set_title(f"Acoustic Rhythm Alignment (Envelope Correlation = {max_corr:.3f})", fontsize=11, fontweight='bold')
axes[2].set_xlabel("Time (seconds)")
axes[2].set_ylabel("Normalized Energy")
axes[2].legend(loc='upper right')
axes[2].grid(True, alpha=0.3)
axes[2].set_xlim(0, dur_rec)

plt.tight_layout()
plt.savefig(PNG_PATH, dpi=150)
print(f"Saved plot: {PNG_PATH}")

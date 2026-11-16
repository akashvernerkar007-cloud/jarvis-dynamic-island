import os
import sys
import time
import threading
import numpy as np
import sounddevice as sd
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
from faster_whisper import WhisperModel

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

print("Initializing Faster-Whisper base.en model...")
model = WhisperModel("base.en", device="cpu", compute_type="int8")
print("Whisper model loaded and ready!")

is_recording = False
audio_buffer = []
lock = threading.Lock()
fs = 16000

def audio_callback(indata, frames, time_info, status):
    global is_recording, audio_buffer
    if is_recording:
        with lock:
            audio_buffer.append(indata.copy())

# Open audio stream once
try:
    stream = sd.InputStream(samplerate=fs, channels=1, dtype='float32', callback=audio_callback)
    stream.start()
    print("Microphone stream initialized successfully on default input device.")
except Exception as e:
    print(f"Error opening audio stream: {e}")

@app.get("/health")
def health():
    return {"status": "ok", "recording": is_recording}

@app.post("/start")
def start_listen():
    global is_recording, audio_buffer
    with lock:
        audio_buffer = []
        is_recording = True
    print("Recording started...")
    return {"status": "recording"}

@app.post("/stop")
def stop_listen():
    global is_recording, audio_buffer
    with lock:
        is_recording = False
        if not audio_buffer:
            return {"text": ""}
        audio_data = np.concatenate(audio_buffer, axis=0).flatten()
        audio_buffer = []

    # If audio is too short (< 0.25s) or basically silence
    if len(audio_data) < int(fs * 0.25) or np.max(np.abs(audio_data)) < 0.002:
        print("Audio too short or silent.")
        return {"text": ""}

    try:
        t0 = time.time()
        segments, _ = model.transcribe(audio_data, language="en", beam_size=1, temperature=0.0, vad_filter=True)
        text = " ".join([seg.text.strip() for seg in segments]).strip()
        t1 = time.time()
        print(f"Whisper transcribed in {t1 - t0:.2f}s: '{text}'")
        return {"text": text}
    except Exception as e:
        print(f"Transcription error: {e}")
        return {"text": "", "error": str(e)}

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="warning")

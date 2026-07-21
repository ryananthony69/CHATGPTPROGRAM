import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import requests
from jiwer import wer

HOST = os.environ.get("HOST", "https://www.serveurperso.com/ia/music").rstrip("/")
OUT = Path("final")
RAW = Path("raw")
OUT.mkdir(exist_ok=True)
RAW.mkdir(exist_ok=True)
session = requests.Session()
session.headers.update({"User-Agent": "song-quality-shootout/2.0"})

LYRICS = """[Intro]
Turn it on.

[Verse 1]
Hoodie on the chair,
Why you standing there?
I know you're just a sleeve,
But tonight I don't believe.

Cat stares past my head,
Then he leaves the bed.
If he sees what I can't see,
That's between the ghost and me.

[Chorus]
Turn on the light, turn on the light.
Everything gets taller in the middle of the night.
Turn on the light, turn on the light.
I'm brave enough tomorrow. I'm unavailable tonight.

[Verse 2]
Phone at one percent,
Charger by the vent.
Six feet from my bed
Might as well be Mars instead.

Roomba starts at three.
Now it's coming straight for me.
If a ghost is living free,
It can split the gas with me.

[Bridge]
Basement pull-chain,
Absolutely insane.
Kill the light and run upstairs.
I was never really scared.

[Final Chorus]
Turn on the light, turn on the light.
Everything gets taller in the middle of the night.
Turn on the light, turn on the light.
I'm brave enough tomorrow. I'm unavailable tonight.

[Outro]
It was the cat.
"""

PROMPT = (
    "mid-tempo 2000s power-pop and indie pop-rock comedy song at 118 BPM, natural expressive adult male lead singer, "
    "warm slightly raspy voice with very clear diction, intimate nervous verses and a large melodic singalong chorus, "
    "bright crunchy electric guitars, real punchy drums, melodic bass, subtle spooky organ, restrained backing harmonies, "
    "dry humor sung completely sincerely, polished radio mix, strong verse-to-chorus dynamics, immediate guitar hook"
)
NEGATIVE = (
    "spoken word, narration, rap, robotic voice, text to speech, vocoder, monotone vocal, chipmunk voice, "
    "metal growl, horror scream, children's choir, muddy mix, muffled vocal, long instrumental intro, rushed lyrics"
)

(OUT / "Lyrics.txt").write_text(LYRICS, encoding="utf-8")
(OUT / "Prompt.txt").write_text(PROMPT, encoding="utf-8")


def get_json(path):
    r = session.get(HOST + path, timeout=30)
    r.raise_for_status()
    return r.json()


props = get_json("/props")
health = get_json("/health")
(RAW / "props.json").write_text(json.dumps(props, indent=2), encoding="utf-8")
(RAW / "health.json").write_text(json.dumps(health, indent=2), encoding="utf-8")

required = {
    "lm": "acestep-5Hz-lm-4B-Q8_0.gguf",
    "vae": "vae-BF16.gguf",
    "xl_sft": "acestep-v15-xl-sft-Q8_0.gguf",
    "std_sft": "acestep-v15-sft-Q8_0.gguf",
    "xl_sft50": "acestep-v15-xl-sftturbo50-Q8_0.gguf",
}
available = props.get("models", {})
assert required["lm"] in available.get("lm", []), "4B LM unavailable"
assert required["vae"] in available.get("vae", []), "official VAE unavailable"
for key in ("xl_sft", "std_sft", "xl_sft50"):
    assert required[key] in available.get("dit", []), f"{required[key]} unavailable"

profiles = [
    {"name": "xl_sft", "model": required["xl_sft"], "adapter": "", "adapter_scale": 1.0},
    {"name": "standard_sft", "model": required["std_sft"], "adapter": "", "adapter_scale": 1.0},
    {"name": "xl_sft50", "model": required["xl_sft50"], "adapter": "", "adapter_scale": 1.0},
]
if "garage-band.safetensors" in props.get("adapters", []):
    profiles.append({"name": "xl_sft_garage", "model": required["xl_sft"], "adapter": "garage-band.safetensors", "adapter_scale": 0.35})


def submit(endpoint, payload):
    last = None
    for _ in range(12):
        r = session.post(HOST + endpoint, json=payload, timeout=90)
        last = r
        if r.status_code == 503:
            time.sleep(int(r.headers.get("Retry-After", "5")))
            continue
        r.raise_for_status()
        data = r.json()
        job_id = data.get("id") or data.get("job_id")
        if not job_id:
            raise RuntimeError(f"No job id from {endpoint}: {data}")
        return job_id
    raise RuntimeError(f"Server remained busy at {endpoint}: {last.text[:300] if last else ''}")


def wait_job(job_id, limit=900):
    for _ in range(limit):
        r = session.get(HOST + "/job", params={"id": job_id}, timeout=30)
        r.raise_for_status()
        data = r.json()
        status = data.get("status")
        if status == "done":
            result = session.get(HOST + "/job", params={"id": job_id, "result": 1}, timeout=180)
            result.raise_for_status()
            return result
        if status in {"failed", "cancelled"}:
            raise RuntimeError(f"Job {job_id} failed: {data}")
        time.sleep(3)
    raise TimeoutError(f"Job {job_id} timed out")


blueprints = []
for blueprint_index, lm_seed in enumerate((72619, 48151623), 1):
    request = {
        "name": f"Turn On the Light blueprint {blueprint_index}",
        "caption": PROMPT,
        "lyrics": LYRICS,
        "bpm": 118,
        "duration": 92,
        "keyscale": "D major",
        "timesignature": "4",
        "vocal_language": "en",
        "lm_model": required["lm"],
        "lm_seed": lm_seed,
        "seed": lm_seed,
        "lm_temperature": 0.68,
        "lm_cfg_scale": 2.7,
        "lm_top_p": 0.88,
        "lm_top_k": 0,
        "lm_negative_prompt": NEGATIVE,
        "use_cot_caption": False,
        "lm_batch_size": 1,
        "output_format": "mp3",
        "mp3_bitrate": 256,
    }
    (RAW / f"blueprint_request_{blueprint_index}.json").write_text(json.dumps(request, indent=2), encoding="utf-8")
    lm_id = submit("/lm", request)
    response = wait_job(lm_id)
    result = response.json()
    if isinstance(result, dict):
        result = result.get("results") or result.get("data") or [result]
    if not isinstance(result, list):
        result = [result]
    if not result:
        raise RuntimeError(f"Empty LM result for seed {lm_seed}")
    blueprint = result[0]
    if isinstance(blueprint, str):
        blueprint = json.loads(blueprint)
    blueprints.append(blueprint)
    (RAW / f"blueprint_{blueprint_index}.json").write_text(json.dumps(blueprint, indent=2), encoding="utf-8")

audio_files = []
errors = []
serial = 0
for blueprint_index, blueprint in enumerate(blueprints, 1):
    active_profiles = profiles if blueprint_index == 1 else profiles[:3]
    for profile in active_profiles:
        serial += 1
        candidate = dict(blueprint)
        candidate.update({
            "name": f"Turn On the Light B{blueprint_index} {profile['name']}",
            "caption": PROMPT,
            "lyrics": LYRICS,
            "bpm": 118,
            "duration": 92,
            "keyscale": "D major",
            "timesignature": "4",
            "vocal_language": "en",
            "seed": 9000 + serial * 173,
            "synth_model": profile["model"],
            "vae": required["vae"],
            "adapter": profile["adapter"],
            "adapter_scale": profile["adapter_scale"],
            "inference_steps": 50,
            "guidance_scale": 1.0,
            "shift": 1.0,
            "solver": "euler",
            "output_format": "mp3",
            "mp3_bitrate": 256,
            "lm_negative_prompt": NEGATIVE,
        })
        tag = f"b{blueprint_index}_{profile['name']}"
        (RAW / f"request_{tag}.json").write_text(json.dumps(candidate, indent=2), encoding="utf-8")
        try:
            synth_id = submit("/synth", candidate)
            audio_response = wait_job(synth_id)
            path = RAW / f"candidate_{tag}.mp3"
            path.write_bytes(audio_response.content)
            if path.stat().st_size < 10000:
                raise RuntimeError(f"small result: {path.stat().st_size} bytes")
            audio_files.append(path)
        except Exception as exc:
            errors.append({"candidate": tag, "error": f"{type(exc).__name__}: {exc}"})

(RAW / "generation_errors.json").write_text(json.dumps(errors, indent=2), encoding="utf-8")
if len(audio_files) < 2:
    raise RuntimeError(f"Only {len(audio_files)} valid candidates; errors={errors}")

separated_root = RAW / "separated"
for audio in audio_files:
    try:
        subprocess.run([
            "python", "-m", "demucs", "--two-stems=vocals", "-n", "htdemucs",
            "--out", str(separated_root), str(audio)
        ], check=True, timeout=900)
    except Exception as exc:
        errors.append({"candidate": audio.stem, "demucs_error": f"{type(exc).__name__}: {exc}"})

from faster_whisper import WhisperModel
whisper = WhisperModel("small.en", device="cpu", compute_type="int8")


def norm(text):
    text = re.sub(r"\[[^]]+\]", " ", text.lower())
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    return " ".join(text.split())


expected = norm(LYRICS)
rows = []
for source in audio_files:
    master = OUT / (source.stem + "_mastered.mp3")
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error", "-i", str(source),
        "-af", "highpass=f=32,loudnorm=I=-14:TP=-1.0:LRA=10",
        "-codec:a", "libmp3lame", "-b:a", "256k", str(master)
    ], check=True)
    vocal_wav = separated_root / "htdemucs" / source.stem / "vocals.wav"
    transcription_source = vocal_wav if vocal_wav.exists() else master
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration,size",
        "-of", "json", str(master)
    ], text=True))["format"]
    duration = float(probe.get("duration", 0))
    segments, _ = whisper.transcribe(str(transcription_source), beam_size=5, vad_filter=True, language="en")
    transcript = " ".join(segment.text.strip() for segment in segments).strip()
    clean = norm(transcript)
    words = clean.split()
    lyric_wer = wer(expected, clean) if clean else 2.0
    hook = clean.count("turn on the light")
    keywords = sum(1 for keyword in ["hoodie", "chair", "cat", "roomba", "ghost", "light", "gas"] if keyword in clean)
    duration_score = 12 if 70 <= duration <= 105 else max(0, 12 - abs(duration - 92) * 0.3)
    adherence = max(0, 50 * (1 - min(1.0, lyric_wer)))
    score = adherence + min(24, hook * 6) + keywords * 2.5 + duration_score + min(10, len(words) / 10)
    accepted = hook >= 1 and len(words) >= 45 and keywords >= 2 and 65 <= duration <= 110
    rows.append({
        "file": str(master),
        "source": str(source),
        "vocal_source": str(transcription_source),
        "duration": duration,
        "transcript": transcript,
        "transcript_words": len(words),
        "wer": lyric_wer,
        "hook_count": hook,
        "keywords": keywords,
        "score": score,
        "accepted": accepted,
    })

rows.sort(key=lambda row: (row["accepted"], row["score"]), reverse=True)
(OUT / "Analysis.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
lines = []
for index, row in enumerate(rows, 1):
    lines.append(
        f"{index}. {Path(row['file']).name}: accepted={row['accepted']}, score={row['score']:.2f}, "
        f"duration={row['duration']:.1f}, words={row['transcript_words']}, WER={row['wer']:.3f}, "
        f"hook={row['hook_count']}, keywords={row['keywords']}"
    )
    lines.append(f"Transcript: {row['transcript']}")
    lines.append("")
(OUT / "Analysis.txt").write_text("\n".join(lines), encoding="utf-8")
print("\n".join(lines))

accepted = [row for row in rows if row["accepted"]]
if not accepted:
    raise RuntimeError("All renders failed the vocal intelligibility gate; refusing to label one finished")
best = Path(accepted[0]["file"])
shutil.copy2(best, OUT / "Afraid_of_the_Dark_Best_Render.mp3")
subprocess.run([
    "ffmpeg", "-y", "-loglevel", "error", "-ss", "8", "-t", "30", "-i", str(best),
    "-codec:a", "libmp3lame", "-b:a", "192k", str(OUT / "Afraid_of_the_Dark_Best_Preview.mp3")
], check=True)

#!/usr/bin/env python3
"""Encode real Unity capture frames with editorial titles and a restrained original score.

Usage (bundled Python includes NumPy):
  python3 scripts/edit-showcase.py
  python3 scripts/edit-showcase.py --input Logs/showcase-capture --output Videos/Soaring-showcase.mp4

The PNG frames are the sole visual source. Titles/disclosure are ordinary video overlays.
Game audio is the exported procedural sound library, placed at recorded manifest event times.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FFMPEG = Path("/Users/don/.juicylucy/bin/ffmpeg")
NAVY = "0x10232D"
CREAM = "0xFAEFD1"
TEAL = "0x80D6BF"
GOLD = "0xFDBC52"
DISCLOSURE = "In-engine footage  •  Scripted controls  •  Progression accelerated"

# Editorial copy follows the capture timeline; it never claims physical headset footage.
CAPTIONS = [
    (4, 11, "01 / ARM-POWERED FLIGHT", "Your arms are wings.", "Big strokes. Immediate lift. A relaxed glide."),
    (11, 19, "02 / CATCH & GROW", "Small birds. Big opportunity.", "Chase the gold. Catch what is smaller than you."),
    (19, 25, "03 / THE SKY HUNTS BACK", "Stay one turn ahead.", "Coral hunters close in. Bank away and escape."),
    (25, 31, "04 / THREAD THE VALLEY", "Find your own flight line.", "Open windows. Tight gaps. Room for acrobatics."),
    (31, 37, "05 / RIDE THE RISING AIR", "Let the valley lift you.", "Catch a thermal. Climb without a wingbeat."),
    (37, 40, "06 / A NEW PERSPECTIVE", "Grow into the sky.", "Your world gets smaller. Your wings get stronger."),
    (40, 43, "07 / APEX", "Become the biggest bird.", "Faster. Heavier. A new goal on the skyline."),
    (43, 46, "08 / THE CROWN CIRCUIT", "Claim the skyline.", "Three crowns. One final flight."),
    (46, 49, "08 / THE CROWN CIRCUIT", "Keep your line.", "Bank into the next crown."),
    (49, 52, "08 / THE CROWN CIRCUIT", "The sky is yours.", "Complete the circuit. Rule the valley."),
    (52, 56, "09 / FIND YOUR FLIGHT FEEL", "Your flight, your way.", "Tune every stroke, turn and glide in the flight lab."),
]


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", type=Path, default=ROOT / "Logs/showcase-capture")
    p.add_argument("--output", type=Path, default=ROOT / "Videos/Soaring-showcase.mp4")
    p.add_argument("--ffmpeg", type=Path, default=DEFAULT_FFMPEG)
    p.add_argument("--no-music", action="store_true", help="Keep the captured game effects and wind; omit the bell score")
    p.add_argument("--music-gain", type=float, default=1, help="Scale the quiet procedural bed (default 1)")
    p.add_argument("--crf", type=int, default=18, help="H.264 quality, smaller is higher (default 18)")
    p.add_argument("--preset", default="medium", help="libx264 preset (default medium)")
    return p


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as f:
        header = f.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not a valid PNG capture frame: {path}")
    return struct.unpack(">II", header[16:24])


def read_capture(folder: Path) -> dict:
    data = json.loads((folder / "manifest.json").read_text())
    fps, frames = float(data["fps"]), int(data["frames"])
    duration = float(data["duration"])
    if fps <= 0 or frames <= 0 or duration <= 0:
        raise ValueError("Capture fps, frames and duration must be positive")
    if abs(frames / fps - duration) > 1 / fps + .001:
        raise ValueError("Manifest duration does not agree with its frame count / fps")
    for i in range(frames):
        path = folder / f"frame_{i:05d}.png"
        if not path.is_file():
            raise FileNotFoundError(f"Capture is incomplete: missing {path.name}")
    size = png_size(folder / "frame_00000.png")
    if size != (int(data["width"]), int(data["height"])):
        raise ValueError(f"Frame size {size} differs from the capture manifest")
    if size != png_size(folder / f"frame_{frames - 1:05d}.png"):
        raise ValueError("Capture frame dimensions changed during the recording")
    return data


def load_wave(path: Path, target_rate: int) -> np.ndarray:
    with wave.open(str(path), "rb") as stream:
        channels, rate, width = stream.getnchannels(), stream.getframerate(), stream.getsampwidth()
        raw = stream.readframes(stream.getnframes())
    if width == 1:
        values = (np.frombuffer(raw, np.uint8).astype(np.float32) - 128) / 128
    elif width == 2:
        values = np.frombuffer(raw, "<i2").astype(np.float32) / 32768
    elif width == 3:
        b = np.frombuffer(raw, np.uint8).reshape(-1, 3).astype(np.int32)
        integers = b[:, 0] | b[:, 1] << 8 | b[:, 2] << 16
        integers = (integers ^ 0x800000) - 0x800000
        values = integers.astype(np.float32) / 8388608
    elif width == 4:
        values = np.frombuffer(raw, "<i4").astype(np.float32) / 2147483648
    else:
        raise ValueError(f"Unsupported PCM sample width {width}: {path}")
    values = values.reshape(-1, channels).mean(axis=1)
    if rate != target_rate:
        count = round(len(values) * target_rate / rate)
        values = np.interp(np.arange(count) * rate / target_rate, np.arange(len(values)), values).astype(np.float32)
    return values


def add_audio(mix: np.ndarray, audio: np.ndarray, seconds: float, gain: float, pan: float = 0) -> None:
    rate = 24000
    start = round(seconds * rate)
    if start < 0:
        audio = audio[-start:]
        start = 0
    count = min(len(audio), len(mix) - start)
    if count <= 0:
        return
    angle = (np.clip(pan, -1, 1) + 1) * math.pi / 4
    mix[start:start + count, 0] += audio[:count] * gain * math.cos(angle)
    mix[start:start + count, 1] += audio[:count] * gain * math.sin(angle)


def bell(frequency: float, length: float = 1.2) -> np.ndarray:
    t = np.arange(round(length * 24000), dtype=np.float32) / 24000
    envelope = np.minimum(t / .015, 1) * np.exp(-t * 4.5) * np.minimum((length - t) / .08, 1)
    phase = t * (2 * math.pi * frequency)
    return ((np.sin(phase) + .22 * np.sin(phase * 2) * np.exp(-t * 3)
             + .07 * np.sin(phase * 3.003) * np.exp(-t * 10)) * envelope).astype(np.float32)


def musical_bed(mix: np.ndarray, duration: float, gain: float) -> None:
    """Original C-major pentatonic motif, warm sine chords and faint air-like rhythm."""
    beat = .625  # 96 bpm, exactly 24 bars in the 60-second edit.
    chords = [(130.813, 164.814, 195.998), (110, 164.814, 220),
              (146.832, 195.998, 246.942), (130.813, 195.998, 261.626)]
    melody = [523.251, 659.255, 783.991, 587.330, 659.255, 880, 783.991, 659.255]
    rng = np.random.default_rng(19731)
    for bar in range(math.ceil(duration / (4 * beat))):
        start = bar * 4 * beat
        chord = chords[(bar // 2) % len(chords)]
        t = np.arange(round(3 * 24000), dtype=np.float32) / 24000
        envelope = np.minimum(t / .22, 1) * np.exp(-t * .7) * np.minimum((3 - t) / .4, 1)
        pad = sum(np.sin(2 * math.pi * note * t) for note in chord) * envelope / 3
        add_audio(mix, pad.astype(np.float32), start, .038 * gain, -.1)
        for offset in (0, 1.5, 3):
            note = melody[(bar * 3 + int(offset * 2)) % len(melody)]
            add_audio(mix, bell(note), start + offset * beat, .034 * gain, .2 * math.sin(bar))
        # No drum kit: a very soft filtered breath supplies a little movement.
        for subdivision in range(8):
            noise = rng.uniform(-1, 1, 1600).astype(np.float32)
            noise = np.convolve(noise, np.ones(9, dtype=np.float32) / 9, "same")
            noise *= np.exp(-np.arange(1600, dtype=np.float32) / 280)
            add_audio(mix, noise, start + subdivision * beat / 2, .012 * gain, -.15)


def mix_audio(folder: Path, capture: dict, destination: Path, music: bool, music_gain: float) -> dict:
    duration = float(capture["duration"])
    mix = np.zeros((round(duration * 24000), 2), dtype=np.float32)
    if music:
        musical_bed(mix, duration, music_gain)
    cache: dict[str, np.ndarray] = {}
    events = capture.get("events", [])
    # A quiet bed uses the game's exported breeze, rather than a stock ambience track.
    wind_path = folder / "audio/wind.wav"
    has_recorded_wind = any(Path(str(event.get("clip", ""))).stem == "wind" for event in events)
    if wind_path.exists() and not has_recorded_wind:
        wind = load_wave(wind_path, 24000)
        if len(wind):
            for position in np.arange(0, duration, len(wind) / 24000):
                add_audio(mix, wind, float(position), .19)
    mixed_events = 0
    victory_mixed = False
    for event in events:
        name = Path(str(event["clip"])).stem
        # Session change notifications can repeat after winning or opening pause.
        if name == "victory":
            if victory_mixed:
                continue
            victory_mixed = True
        if name not in cache:
            path = folder / "audio" / f"{name}.wav"
            if not path.exists():
                raise FileNotFoundError(f"Captured audio event references an unavailable clip: {path}")
            cache[name] = load_wave(path, 24000)
        add_audio(mix, cache[name], float(event["time"]), float(event.get("gain", 1)) * .8)
        mixed_events += 1
    # Smooth in/out, preserve the effects' transients and prevent clipping without hard limiting.
    fade = min(round(1.1 * 24000), len(mix) // 2)
    if fade:
        mix[:fade] *= np.linspace(0, 1, fade, dtype=np.float32)[:, None]
        mix[-fade:] *= np.linspace(1, 0, fade, dtype=np.float32)[:, None]
    peak = float(np.max(np.abs(mix))) if len(mix) else 0
    if peak > .88:
        mix *= .88 / peak
    pcm = np.round(np.clip(mix, -1, 1) * 32767).astype("<i2")
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(24000)
        output.writeframes(pcm.tobytes())
    return {"events": mixed_events, "peak_before_normalization": peak,
            "music": "original procedural bell score" if music else "none"}


def font_path(bold: bool = False) -> Path:
    candidates = [Path("/System/Library/Fonts/Supplemental") / ("Arial Bold.ttf" if bold else "Arial.ttf"),
                  Path("/usr/share/fonts/truetype/dejavu") / ("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf")]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("A readable Arial or DejaVu font is required for the trailer captions")


def build_filter(work: Path, duration: float) -> str:
    filters = ["scale=1920:1080:force_original_aspect_ratio=increase", "crop=1920:1080", "setsar=1"]
    count = 0

    def title(text: str, x: str | int, y: int, size: int, color: str, start: float, end: float, bold=False):
        nonlocal count
        if start >= duration:
            return
        end = min(duration, end)
        textfile = work / f"title-{count:02d}.txt"
        textfile.write_text(text, encoding="utf-8")
        count += 1
        alpha = f"min(1,min(max(0,(t-{start})/0.35),max(0,({end}-t)/0.25)))"
        filters.append(f"drawtext=fontfile='{font_path(bold)}':textfile='{textfile}':expansion=none:"
                       f"fontsize={size}:fontcolor={color}:x={x}:y={y}:shadowcolor={NAVY}@0.75:"
                       f"shadowx=1:shadowy=2:alpha='{alpha}':enable='between(t,{start},{end})'")

    def box(x: int, y: int, w: int, h: int, color: str, start: float, end: float):
        if start < duration:
            filters.append(f"drawbox=x={x}:y={y}:w={w}:h={h}:color={color}:t=fill:"
                           f"enable='between(t,{start},{min(end,duration)})'")

    # Keep the disclosure on its own narrow bottom strip, below the gameplay HUD.
    box(64, 1010, 1792, 44, NAVY + "@0.82", 0, duration)
    title(DISCLOSURE, "(w-text_w)/2", 1020, 22, CREAM, 0, duration)
    box(88, 62, 790, 210, NAVY + "@0.72", 0, 4)
    box(88, 62, 6, 210, GOLD + "@0.94", 0, 4)
    title("S O A R I N G", 126, 78, 74, CREAM, .1, 3.85, True)
    title("Small wings. Big sky.", 130, 170, 35, GOLD, .4, 3.85)
    title("An arm-powered VR food chain", 130, 217, 24, CREAM, .65, 3.85)
    for start, end, label, heading, subtitle in CAPTIONS:
        lab = start == 52
        y, height = (20, 136) if lab else (62, 156)
        box(88, y, 1005, height, NAVY + "@0.79", start, end)
        box(88, y, 5, height, GOLD + "@0.95", start, end)
        title(label, 118, y + 19, 19, GOLD, start + .05, end - .12, True)
        title(heading, 118, y + 50, 34 if lab else 40, CREAM, start + .1, end - .12, True)
        title(subtitle, 118, y + (96 if lab else 104), 22 if lab else 25, CREAM, start + .15, end - .12)
    box(88, 62, 790, 210, NAVY + "@0.72", 56, duration)
    box(88, 62, 6, 210, GOLD + "@0.94", 56, duration)
    title("S O A R I N G", 126, 78, 74, CREAM, 56.05, duration - .1, True)
    title("Own the sky.", 130, 170, 36, GOLD, 56.2, duration - .1)
    title("Built in Unity for Meta Quest", 130, 219, 25, CREAM, 56.4, duration - .1)
    return "[0:v]" + ",\n".join(filters) + ",format=yuv420p[v]"


def verify_video(ffmpeg: Path, output: Path, capture: dict) -> dict:
    ffprobe = ffmpeg.with_name("ffprobe")
    if not ffprobe.exists():
        found = shutil.which("ffprobe")
        if found:
            ffprobe = Path(found)
        else:
            # Decode completely when this ffmpeg bundle has no companion ffprobe.
            subprocess.run([str(ffmpeg), "-v", "error", "-i", str(output), "-f", "null", "-"], check=True)
            return {"decoded": True, "probe": "unavailable"}
    result = subprocess.run([str(ffprobe), "-v", "error", "-show_entries",
                             "stream=codec_type,codec_name,width,height,pix_fmt,r_frame_rate,nb_frames:format=duration,size",
                             "-of", "json", str(output)], check=True, capture_output=True, text=True)
    data = json.loads(result.stdout)
    video = next(s for s in data["streams"] if s["codec_type"] == "video")
    audio = next(s for s in data["streams"] if s["codec_type"] == "audio")
    if (video["width"], video["height"], video["codec_name"], video["pix_fmt"]) != (1920, 1080, "h264", "yuv420p"):
        raise ValueError(f"Unexpected video format: {video}")
    if audio["codec_name"] != "aac":
        raise ValueError(f"Unexpected audio format: {audio}")
    numerator, denominator = map(float, video["r_frame_rate"].split("/"))
    if abs(numerator / denominator - float(capture["fps"])) > .001:
        raise ValueError("Encoded frame rate differs from the capture manifest")
    if video.get("nb_frames", "N/A") != "N/A" and int(video["nb_frames"]) != int(capture["frames"]):
        raise ValueError("Encoded video frame count differs from the captured footage")
    if abs(float(data["format"]["duration"]) - float(capture["duration"])) > .12:
        raise ValueError("Encoded video duration differs from captured footage")
    return data


def main() -> None:
    args = parser().parse_args()
    folder, output = args.input.resolve(), args.output.resolve()
    capture = read_capture(folder)
    if not args.ffmpeg.exists():
        raise FileNotFoundError(f"ffmpeg was not found: {args.ffmpeg}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="soaring-showcase-") as temporary:
        work = Path(temporary)
        audio = work / "showcase-mix.wav"
        audio_info = mix_audio(folder, capture, audio, not args.no_music, max(0, args.music_gain))
        script = work / "trailer-filter.txt"
        script.write_text(build_filter(work, float(capture["duration"])))
        command = [str(args.ffmpeg), "-hide_banner", "-y", "-framerate", str(capture["fps"]),
                   "-start_number", "0", "-i", str(folder / "frame_%05d.png"), "-i", str(audio),
                   "-filter_complex_script", str(script), "-map", "[v]", "-map", "1:a:0",
                   "-frames:v", str(capture["frames"]), "-r", str(capture["fps"]),
                   "-c:v", "libx264", "-preset", args.preset, "-crf", str(args.crf),
                   "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
                   "-af", "loudnorm=I=-20:TP=-2:LRA=9",
                   "-movflags", "+faststart", "-t", str(capture["duration"]),
                   "-metadata", "title=Soaring — Small wings. Big sky.",
                   "-metadata", "comment=In-engine footage; scripted controls; progression accelerated. " +
                   ("Original procedural score." if not args.no_music else "Captured game audio."),
                   str(output)]
        subprocess.run(command, check=True)
    encoded = verify_video(args.ffmpeg, output, capture)
    report = {"output": str(output), "source": str(folder), "capture": capture,
              "audio_mix": audio_info, "encoded": encoded,
              "audio_master": "EBU R128 loudnorm, target -20 LUFS / -2 dBTP / 9 LU LRA",
              "disclosure": DISCLOSURE, "visual_source": "Unity in-engine capture frames only"}
    output.with_suffix(".json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"Showcase ready: {output}")


if __name__ == "__main__":
    main()

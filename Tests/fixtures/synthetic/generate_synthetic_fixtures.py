"""Generates the twelve fixtures with macOS `say`, as placeholders until real recordings exist (@weak).

Usage: python3 generate_synthetic_fixtures.py   (writes <id>.wav and <id>.expected.txt next to this script)
"""
import array
import math
import os
import random
import subprocess
import tempfile
import wave

directory = os.path.dirname(os.path.abspath(__file__))
long_text = open(os.path.join(directory, "long-15min.txt")).read().split()

rant = ("So the thing about the settings window is that, um, it scrolls when it really should not, and uh "
        "I think the fix is to size the window to its content instead of hiding the scroll bar. Um, the other "
        "thing is the pill, it should fade in and out quickly and never take focus from the app I am typing in.")
noise_rant = rant + (" Also the train is loud right now so, uh, let us see how well it copes with all of this "
                     "background noise while I keep talking about the release plan for Friday.")

fixtures = [
    ("01-quiet-short", "Add a scroll bar fix to the settings window.", "Add a scroll bar fix to the settings window.", None),
    ("02-quiet-names", "Ask Claude Code to check CLAUDE.md, then restart the MCP server and the SwiftUI preview.",
     "Ask Claude Code to check CLAUDE.md, then restart the MCP server and the SwiftUI preview.", None),
    ("03-quiet-punct", "Hello comma this is a test period Is it working question mark",
     "Hello, this is a test. Is it working?", None),
    ("04-quiet-fillers", rant, rant, None),
    ("05-quiet-pause", "I think we should [[slnc 4000]] ship the release on Friday.", "I think we should ship the release on Friday.", None),
    ("06-quiet-long", " ".join(long_text[:520]), " ".join(long_text[:520]), None),
    ("07-noise-short", "Add a scroll bar fix to the settings window.", "Add a scroll bar fix to the settings window.", "noise"),
    ("08-noise-rant", noise_rant, noise_rant, "noise"),
    ("09-headset-rant", rant, rant, "headset"),
    ("10-scratch-that", "Let's send it tomorrow, scratch that, send it today.", "Send it today.", None),
    ("11-empty-press", None, "", "silence:1.0"),
    ("12-too-short", None, "", "silence:0.2"),
]


def read_pcm(path):
    with wave.open(path) as source:
        return array.array("h", source.readframes(source.getnframes()))


def write_pcm(path, samples, rate=16000):
    with wave.open(path, "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(rate)
        target.writeframes(samples.tobytes())


def speak(text, path, rate=16000):
    with tempfile.TemporaryDirectory() as temporary:
        spoken = os.path.join(temporary, "spoken.aiff")
        subprocess.run(["say", "-o", spoken, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{rate}", "-c", "1", spoken, path], check=True)


random.seed(7)
for identifier, spoken_text, expected, treatment in fixtures:
    output = os.path.join(directory, identifier + ".wav")
    if treatment and treatment.startswith("silence:"):
        seconds = float(treatment.split(":")[1])
        samples = array.array("h", (int(random.gauss(0, 20)) for _ in range(int(16000 * seconds))))
        write_pcm(output, samples)
    elif treatment == "headset":
        # Simulates a Bluetooth headset microphone in call mode: 8 kHz sampling, so nothing above 4 kHz survives.
        with tempfile.TemporaryDirectory() as temporary:
            narrow = os.path.join(temporary, "narrow.wav")
            speak(spoken_text, narrow, rate=8000)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", narrow, output], check=True)
    else:
        speak(spoken_text, output)
        if treatment == "noise":
            samples = read_pcm(output)
            power = sum(sample * sample for sample in samples) / max(len(samples), 1)
            # Gaussian broadband noise whose power is 10 dB below the mean power of the speech.
            deviation = math.sqrt(power / 10)
            mixed = array.array("h", (max(-32768, min(32767, int(sample + random.gauss(0, deviation)))) for sample in samples))
            write_pcm(output, mixed)
    with open(os.path.join(directory, identifier + ".expected.txt"), "w") as handle:
        handle.write(expected + "\n")

open(os.path.join(directory, "SYNTHETIC"), "w").write("Generated with macOS say. Results from these fixtures are @weak.\n")
print("wrote", len(fixtures), "fixtures to", directory)

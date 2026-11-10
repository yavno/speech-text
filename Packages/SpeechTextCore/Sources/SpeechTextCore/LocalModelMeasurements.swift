// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

// Written by `scripts/evaluate.sh`; do not edit by hand (docs/audio-corpus.md). Each row
// is one local model on the speech clips of one language: mean word error rate (Auto
// pass) and median seconds from the stop to the text (the warm pass after it).

/// What `localSTTPick` chooses from. A model with no row is not compared at all.
public let localSTTMeasurements: [LocalSTTMeasurement] = [
    LocalSTTMeasurement(model: "bark-3.0", language: "en", clips: 3, wer: 0.037, seconds: 0.227, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "bark-3.0", language: "mixed", clips: 10, wer: 0.747, seconds: 0.134, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "bark-3.0", language: "uk", clips: 29, wer: 0.770, seconds: 0.130, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "bark-3.0-clean", language: "en", clips: 3, wer: 0.063, seconds: 0.222, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "bark-3.0-clean", language: "mixed", clips: 10, wer: 0.696, seconds: 0.134, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "bark-3.0-clean", language: "uk", clips: 29, wer: 0.530, seconds: 0.120, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "openai_whisper-tiny", language: "en", clips: 3, wer: 0.081, seconds: 0.199, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "openai_whisper-tiny", language: "mixed", clips: 10, wer: 0.811, seconds: 0.279, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "openai_whisper-tiny", language: "uk", clips: 29, wer: 0.719, seconds: 0.235, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-redux", language: "en", clips: 3, wer: 0.037, seconds: 0.523, run: "2026-10-16", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-redux", language: "mixed", clips: 10, wer: 0.379, seconds: 0.282, run: "2026-10-16", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-redux", language: "uk", clips: 29, wer: 0.213, seconds: 0.169, run: "2026-10-16", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-tdt-0.6b-v3", language: "en", clips: 3, wer: 0.037, seconds: 0.223, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-tdt-0.6b-v3", language: "mixed", clips: 10, wer: 0.306, seconds: 0.118, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-tdt-0.6b-v3", language: "uk", clips: 29, wer: 0.171, seconds: 0.124, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-ultra", language: "en", clips: 3, wer: 0.037, seconds: 0.228, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-ultra", language: "mixed", clips: 10, wer: 0.270, seconds: 0.122, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "parakeet-ultra", language: "uk", clips: 29, wer: 0.176, seconds: 0.119, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "phonon-2", language: "en", clips: 3, wer: 0.037, seconds: 0.226, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "phonon-2", language: "mixed", clips: 10, wer: 0.802, seconds: 0.124, run: "2026-11-09", mac: "Apple M1 Pro"),
    LocalSTTMeasurement(model: "phonon-2", language: "uk", clips: 29, wer: 1.211, seconds: 0.123, run: "2026-11-09", mac: "Apple M1 Pro"),
]

# Official runner

Copied unchanged from the model repository at the pinned revision
(`ConwayResearch/Underdog-Bark-3.0-Pro`, `4b5c51e04aa8d16dda9ecdff71bc29f7360149e4`): the Swift Core ML runner
(`runtime/coreml/`), the Python runner (`runtime/transcribe_bark_pro.py`), the model README, NOTICE and license
(CC BY 4.0).

`Sources/DictationEngine/SpeechTranscriber.swift` follows `runtime/coreml/Sources/main.swift`: the 0.25 s leading
silence, `short8` up to 8 s including that silence, `full15` otherwise, preprocessor, decoder and joint on the CPU,
and greedy decoding. Compare the two to check the app runs the model the way its authors intended.

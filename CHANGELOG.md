# Changelog

## 1.0.1 (October 30, 2026)

- Long dictation is more accurate where speech is split into chunks. Each chunk is decoded with the audio around it,
  which removes false sentence breaks and misheard words at the joins.
- The last audio before you stop always reaches the transcript.
- Dictations stay in order when a transcription fails, and hotkeys reinstall cleanly after sleep.
- A failed clipboard write no longer pastes old clipboard contents, and an unconfirmed paste no longer overwrites a newer
  copy.
- An out-of-range recording limit in the settings file can no longer crash the app, and a vocabulary file that cannot be
  inspected is no longer replaced.
- Settings banners update as permissions and secure input change.
- Application source is organized by feature.

## 1.0 (October 30, 2026)

First public release.

- Fn starts and stops dictation, and Escape cancels it. Settings offers hold-to-talk, double-tap-to-lock and other
  trigger keys.
- Underdog Bark 3.0 Pro runs on the Neural Engine through Core ML. Speech is transcribed while you talk, in chunks cut
  at pauses, and the audio never touches the disk.
- Text goes into the focused field by Accessibility insertion or paste. When delivery cannot be confirmed, a panel shows
  the text with a Copy button. Password fields never receive text. After a paste, the previous clipboard is restored.
- Per-app text styles, vocabulary corrections, opt-in history and opt-in Markdown transcript files.
- Start and stop sounds with a volume setting.

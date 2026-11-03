# Changelog

## 1.1 (November 3, 2026)

- The indicator is a dithered moon that swells as you talk. Setup, the menu and the app icon use the same moon.
- Setup goes one step at a time: microphone, Accessibility, the speech model download, then a place to try it.
- Settings is a single page. History opens in its own window. Corrections and App Exceptions open as sheets, and
  corrections are edited in a table instead of a text file.
- After setup, you can dictate while the speech model is still loading. The recording waits in memory and is typed once
  the model is ready.
- A parked moon replaces the copy panel. When text cannot be typed, ⌘V or Paste last text recovers it. If the app could
  not confirm the text was typed, check the field first, because it may already be there.
- Fewer failed insertions in apps that rebuild their text field while you talk.
- The menu shows what the app is doing, and adds Show history and Open at login.
- A lock on the menu bar icon shows when another app holds secure input. This replaces the on-screen banner.
- The app checks for updates on its own and asks before installing one.
- Requires macOS 27.
- Removed: automatic sending in chat apps, and the separate text styles. Formatting is now one checkbox, Remove fillers
  and format text, with per-app choices under App Exceptions.

## 1.0.2 (October 31, 2026)

- Long recordings use overlapping speech windows to join words across boundaries.
- Unknown-token markers are removed from transcribed text.
- The recording indicator warns when the microphone is silent or unavailable.

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

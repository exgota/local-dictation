# Changelog

## 1.1.1 (November 5, 2026)

- Text copied after you stop dictating stays on the clipboard, even if focus moves or no text field is selected. Use
  Paste last text to recover the dictation.
- The small parked moon turns into the original document copy icon when the dictation is on the clipboard.
- Paste last text works while another dictation is recording or transcribing. Short or empty recordings keep the
  previous usable text available.
- Text delivery has a time limit. A stalled insertion leaves the text available for recovery and lets later
  dictations continue in order.
- Setup's practice field accepts dictation and shows Done after text arrives. An open setup window cannot take text
  intended for another app.
- Model downloads show arriving progress, report a lost connection within about 15 seconds and offer Try Again. The moon stays just
  below complete until the model is ready.
- Setup and the recording indicator fade in smoothly. Reduce Motion keeps these transitions still.
- The menu uses standard shortcut labels and removes the extra moon and status heading. The secure-input lock keeps
  the menu available and names the app blocking shortcuts when macOS identifies it.
- Opening a copy outside Applications offers to move it. An existing installation is replaced in its current folder,
  including a renamed copy. The downloaded copy stays in Downloads, so macOS does not ask for access to that folder.
- Setup, Settings, History and the Move alert come to the front by themselves, including after System Settings, and
  show Local Dictation in the Dock and in Command-Tab while they are open.
- The app icon uses Apple's Icon Composer format, so System Settings and Finder no longer show it inside a gray box.
- Setup opens centered, stays dark in Light appearance so its moon stays visible, and the Move alert can be read by
  VoiceOver.
- After you allow the microphone in System Settings following a denial, macOS's Quit & Reopen brings setup back on the
  next step.
- Moving the app or reopening a quarantined installation waits for the old process to quit, so the replacement can
  stay running.

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

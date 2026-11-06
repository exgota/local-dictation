# Changelog

## 1.1.2 (November 5, 2026)

- The copy icon now stays for 5 seconds instead of about 2, so there is time to click into a field and press ⌘V.
- Setup now shows one percentage that covers both downloading and preparing the model. At 100% you can dictate. The
  separate "Almost ready…" wait is gone, and the percentage no longer drops after Try Again.
- Setup's practice step now says "Writing it down…" while your words are transcribed. It no longer asks you to press
  the key again. A long sentence in the practice field now ends in an ellipsis where it used to be clipped at the edge.
- When text cannot be typed, the moon now folds into the copy icon: it turns into a page, a second page slides out from
  behind it, and lines appear on the front page.
- After you paste, the copy icon now rises out of view the way the moon does, without changing back into the moon
  first.

## 1.1.1 (November 5, 2026)

- When the app cannot type your words, they now stay on the clipboard even if you click somewhere else first. Paste
  last text brings them back.
- When your dictation is on the clipboard, the small moon now changes into a copy icon.
- Paste last text now works while another dictation is recording or transcribing. A recording that is too short or has
  no words no longer replaces your last dictation.
- If the app gets stuck typing a dictation, it now stops trying and keeps your text for Paste last text. Your next
  dictations still go through in order.
- Setup's practice field now accepts dictation and shows Done after your words arrive. Dictating into another app
  while setup is open no longer types into setup.
- The model download now shows progress as data arrives, tells you within about 15 seconds if the connection drops,
  and offers Try Again. The moon shows completion only once the model is ready.
- Setup and the recording indicator now fade in. With Reduce Motion on, they appear without animation.
- The menu now shows shortcuts the way other Mac menus do, and the extra moon and status heading are gone. When a lock
  shows on the menu bar icon, the menu still opens and names the app blocking shortcuts when macOS reports it.
- If you open Local Dictation from outside Applications, it now offers to copy itself there. An existing installation
  is replaced where it is, even if you renamed it. The file in Downloads is left alone, so macOS does not ask for
  access to that folder.
- Setup, Settings, History and the Move alert now come to the front on their own, including when you come back from
  System Settings. While they are open, Local Dictation shows in the Dock and in Command-Tab.
- The app icon no longer appears inside a gray box in System Settings or Finder.
- Setup now opens centered, and it stays dark in Light appearance so its moon stays visible.
- VoiceOver now reads the Move alert.
- If you first turned down microphone access and then allowed it in System Settings, choosing Quit & Reopen now brings
  setup back at the next step.
- Fixed cases where Local Dictation quit after you moved it or reopened it once macOS allowed it.

## 1.1 (November 3, 2026)

- The recording indicator is now a moon that swells as you talk. Setup, the menu and the app icon use the same moon.
- Setup now goes one step at a time: microphone, Accessibility, the speech model download, then a place to try it.
- Settings is now a single page. History opens in its own window. Corrections and App Exceptions open as sheets, and
  you edit corrections in a table instead of a text file.
- After setup, you can now dictate while the speech model is still loading. The app keeps your recording until the
  model is ready, then transcribes it and types the text.
- When text cannot be typed, a small moon now stays on screen in place of the copy panel, and ⌘V or Paste last text
  gets your words back. If the app could not confirm the text was typed, check the field first, because it may already
  be there.
- Fixed some cases where dictated text did not appear in apps that change their text field while you talk.
- The menu now shows what the app is doing, and adds Show history and Open at login.
- A lock on the menu bar icon now shows when another app, such as a password manager, is protecting what you type, so
  Local Dictation cannot notice the Fn key. This replaces the on-screen banner.
- The app now checks for updates on its own and asks before installing one.
- Requires macOS 27.
- Removed: automatic sending in chat apps, and the separate text styles. Formatting is now one checkbox, Remove fillers
  and format text, with per-app choices under App Exceptions.

## 1.0.2 (October 31, 2026)

- Long recordings now drop or garble fewer words where the audio is split into pieces.
- Stray markers for unrecognized words no longer appear in your text.
- The recording indicator now warns when the microphone is silent or unavailable.

## 1.0.1 (October 30, 2026)

- Long dictations have fewer stray sentence breaks and misheard words where the audio is split.
- Stopping dictation no longer cuts off your last words.
- Dictations stay in order when a transcription fails, and your shortcuts work again after your Mac wakes from sleep.
- If the app cannot put your text on the clipboard, it no longer pastes what was there before. Restoring your
  clipboard no longer erases something you copied in the meantime.
- An out-of-range recording limit in the settings file can no longer crash the app. If the app cannot read your
  vocabulary file, it leaves the file alone instead of replacing it.
- Settings banners now update as permissions and secure input change.
- For contributors: the source code is now organized by feature.

## 1.0 (October 30, 2026)

First public release.

- Fn starts and stops dictation, and Escape cancels it. Settings offers hold to talk, double-tap to lock and other
  trigger keys.
- Underdog Bark 3.0 Pro runs on the Neural Engine through Core ML. The app transcribes your speech while you talk, and
  the audio is never saved to disk.
- Text is typed into the field you are in, or pasted when typing it directly does not work. When the app cannot
  confirm the text arrived, a panel shows it with a Copy button. Password fields never receive text. After a paste,
  your previous clipboard is restored.
- You can set a text style for each app, add vocabulary corrections, and turn on history and Markdown transcript
  files, both off by default.
- A sound plays when dictation starts and stops, with a volume setting.

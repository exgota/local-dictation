#!/bin/zsh
# End-to-end scenarios against the installed app. Speech is played through the speakers into the microphone.
# Usage: run_scenarios.sh SCENARIO...   Each SCENARIO is a case label below.
# Output: each scenario prints its log lines and the document or clipboard text it observed, and writes
# results/<scenario>.log. toggle_bars also saves a screenshot, and long_recording saves its transcript, in results/.
# Requires the installed app and TextEdit (chrome_paste also needs Google Chrome). Compile the key poster first with
# `swiftc -O post_keyboard_events.swift -o post_keyboard_events`. The script sets the output volume to 60 and restores
# the previous volume on exit. hold_right_option rewrites settings.json for its run and restores it afterwards.
set -u
here="${0:A:h}"; keys="$here/post_keyboard_events"; results="$here/results"; mkdir -p "$results"
short="Please schedule the quarterly review for Thursday afternoon and send the agenda to the whole team."
previous_volume=$(osascript -e 'output volume of (get volume settings)')
osascript -e 'set volume output volume 60'
trap 'osascript -e "set volume output volume $previous_volume"' EXIT

start_log() { /usr/bin/log stream --style compact --predicate 'subsystem == "com.exgota.LocalDictation"' > "$results/$1.log" 2>&1 & log_process=$!; sleep 2; }
stop_log() { sleep "${1:-3}"; kill $log_process 2>/dev/null; grep -v "^Filtering\|^Timestamp" "$results/$current.log" | sed 's/.*dictation\] //'; }
close_documents() { osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1; }
fresh_document() { close_documents; printf '%s' "${2:-}" > "$here/$1.txt"; open -a TextEdit "$here/$1.txt"; sleep 1.5; osascript -e 'tell application "TextEdit" to activate'; sleep 0.7; }
document_text() { osascript -e 'tell application "TextEdit" to get text of front document'; }
sentinel() { printf 'clipboard sentinel %s' "$1" | pbcopy; }

for current in "$@"; do
  echo "=== $current"
  case $current in
  toggle_bars)
    fresh_document toggle_bars; sentinel toggle; start_log $current
    "$keys" fn-tap; sleep 0.4; (say "$short" &); sleep 2.2; screencapture -x "$results/toggle_bars_speaking.png"; sleep 4
    "$keys" fn-tap; stop_log 3; echo "document: $(document_text)"; echo "clipboard: $(pbpaste)";;
  fn_chord_ignored)
    fresh_document fn_chord; start_log $current; "$keys" fn-chord; sleep 1; "$keys" option-chord; stop_log 1
    echo "(expect no log lines)";;
  escape_recording)
    fresh_document escape_recording; start_log $current
    "$keys" fn-tap; sleep 0.4; say "$short"; "$keys" escape; stop_log 4; echo "document: [$(document_text)]";;
  escape_transcribing)
    fresh_document escape_transcribing; start_log $current
    "$keys" fn-tap; sleep 0.4; say -f "$here/long-recording-script.txt" & speaker=$!; sleep 40; kill $speaker; "$keys" fn-tap; sleep 0.05; "$keys" escape
    stop_log 6; echo "document: [$(document_text)]";;
  focus_change)
    fresh_document focus_change_first; printf "" > "$here/focus_change_second.txt"; open -a TextEdit "$here/focus_change_second.txt"; sleep 1.5; osascript -e 'tell application "TextEdit" to set index of window "focus_change_first.txt" to 1'; sleep 0.7
    sentinel focus; start_log $current
    "$keys" fn-tap; sleep 0.4; say "$short"; osascript -e 'tell application "Finder" to activate'; sleep 0.7; "$keys" fn-tap
    stop_log 3; osascript -e 'tell application "TextEdit" to get text of every document'; echo "clipboard: $(pbpaste)";;
  selection_undo)
    fresh_document selection_undo "Meeting moved to OLDWORD today."
    osascript -e 'tell application "System Events" to keystroke "f" using command down' -e 'delay 0.5' -e 'tell application "System Events" to keystroke "OLDWORD"' -e 'delay 0.3' -e 'tell application "System Events" to key code 36' -e 'delay 0.3' -e 'tell application "System Events" to key code 53' -e 'delay 0.4'
    start_log $current; "$keys" fn-tap; sleep 0.4; say "Wednesday"; sleep 0.3; "$keys" fn-tap; stop_log 3
    echo "after dictation: $(document_text)"; osascript -e 'tell application "System Events" to keystroke "z" using command down'; sleep 0.5; echo "after undo: $(document_text)";;
  silence)
    fresh_document silence; start_log $current; "$keys" fn-tap; sleep 3; "$keys" fn-tap; stop_log 3; echo "document: [$(document_text)]";;
  short_tap)
    fresh_document short_tap; start_log $current; "$keys" fn-tap; sleep 0.1; "$keys" fn-tap; stop_log 3; echo "document: [$(document_text)]";;
  push_to_talk)
    fresh_document push_to_talk; sentinel hold; start_log $current
    "$keys" option-down; sleep 0.4; say "$short"; sleep 0.3; "$keys" option-up; stop_log 3; echo "document: $(document_text)"; echo "clipboard: $(pbpaste)";;
  push_to_talk_chord)
    fresh_document push_to_talk_chord; start_log $current
    "$keys" option-down; sleep 1; "$keys" option-a; sleep 0.3; "$keys" option-up; stop_log 3; echo "document: [$(document_text)]";;
  overlapping_dictations)
    fresh_document overlapping_dictations; sentinel overlap; start_log $current
    # The second dictation starts 0.15 s after the first stops, while the first is still transcribing.
    "$keys" fn-tap; sleep 0.4; say "First sentence."; sleep 0.2; "$keys" fn-tap; sleep 0.15
    "$keys" fn-tap; sleep 0.3; say "Yes."; sleep 0.2; "$keys" fn-tap
    stop_log 4; echo "document: $(document_text)"; echo "clipboard: $(pbpaste)";;
  first_syllable)
    fresh_document first_syllable; start_log $current; osascript -e "set volume output volume 60"
    (say "Banana bread is ready." &); "$keys" fn-tap; sleep 3; "$keys" fn-tap; stop_log 3; echo "document: $(document_text)";;
  chat_profile)
    fresh_document chat_profile; start_log $current
    "$keys" fn-tap; sleep 0.4; say "Um, so let's send it tomorrow, scratch that, send it today period"; sleep 0.3; "$keys" fn-tap
    stop_log 3; echo "document: $(document_text)";;
  hold_right_option)
    settings_file="$HOME/Library/Application Support/LocalDictation/settings.json"; cp "$settings_file" /tmp/settings_before_hold.json
    python3 -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['trigger']={'rightOption':{}}; d['triggerMode']='hold'; open(p,'w').write(json.dumps(d,indent=2))" "$settings_file"
    sleep 1; fresh_document hold_right_option; sentinel hold; start_log $current
    "$keys" right-option-down; sleep 0.4; say "$short"; sleep 0.3; "$keys" right-option-up; stop_log 3
    echo "document: $(document_text)"; echo "clipboard: $(pbpaste)"; cp /tmp/settings_before_hold.json "$settings_file";;
  chrome_paste)
    open -a "Google Chrome" "file://$here/browser_fields.html"; sleep 3; osascript -e 'tell application "Google Chrome" to activate'; sleep 1
    sentinel chrome; start_log $current
    "$keys" fn-tap; sleep 0.4; say "$short"; sleep 0.3; "$keys" fn-tap; stop_log 4; echo "clipboard after: $(pbpaste)"
    osascript -e 'tell application "System Events" to keystroke "a" using command down' -e 'delay 0.2' -e 'tell application "System Events" to keystroke "c" using command down' -e 'delay 0.3'
    echo "textarea: $(pbpaste)"; osascript -e 'tell application "System Events" to keystroke "w" using command down';;
  long_recording)
    fresh_document long_recording; start_log $current
    "$keys" fn-tap; sleep 0.4; say -f "$here/long-recording-script.txt"; sleep 0.5; "$keys" fn-tap; stop_log 8
    document_text > "$results/long_recording_transcript.txt"; python3 "$here/word_error_rate.py" "$here/long-recording-script.txt" "$results/long_recording_transcript.txt";;
  esac
done

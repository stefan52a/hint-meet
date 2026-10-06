# Changelog

What changes for the user, newest first. Technical details are in `git log`.

## 2026-10-06

### App

- **Conversation language:** choose Nederlands, English, Deutsch, Français or Multilingual (language recognized per utterance) in the panel. Speech recognition uses that language; hints and the report follow the language of the conversation. Previously recognition was fixed to Dutch, so English or German came out half translated.
- **Transcript next to the hint:** the scrollable transcript of the meeting on the left, the hint on the right. The utterance the shown hint responds to is in bold white on a light red background; utterances with a hint have a 💡 (click to show that hint). The transcript follows the newest utterance live and jumps to the hint's utterance when you browse back. In a narrow panel the transcript sits below the hint; the default width is 760 points.
- **Hints as a scrollable list:** on the right, all hints of the meeting in order; the selected one is large in the middle, the rest compact and dimmed. Scrolling through the hints scrolls the transcript to the matching utterance, and vice versa. Click a hint to select it.
- Clicking the text itself (an utterance or a hint) selects it and shows the matching hint or utterance on the other side; an utterance without its own hint shows the hint that was on screen at that moment. Clicking the newest hint scrolls to its utterance, not to the end. You now drag the panel by its header.
- Scrolling through the transcript moves the hint along: on the right is the hint of the 💡 utterance closest to the middle. All the way at the bottom you're live again. If you scroll up, new utterances no longer pull you down.
- The app is in English: menus, buttons, messages and the progress of Load KB and Convert Documents. (Hints and reports follow the conversation language, see above.)
- The *Met wie?* field is now **Meeting info** (for example with whom and where). That text goes into the report name: `2026-10-06-104736-Finance-Jan Jansen, Utrecht.md`.
- **Hint history:** browse back through this meeting's hints with ◀ ▶ above the hint (or ⌘[ and ⌘] in the Meeting menu), with time and the utterance the hint responded to. *Latest* takes you back; new hints arrive without losing your place.
- The menu bar at the top left comes back when you click the panel outside a meeting (HintMeet becomes the active app). During a meeting, clicking the panel header (hint-meet · project) does the same; clicks on hints, ◀ ▶, 👍 and the transcript leave the focus with the meeting app.

### Documentation

- README starts with what HintMeet does, what you use it for and how.
- README in English, updated to the current app (transcript, hint list, language choice, multiple projects, Load KB) and the current project structure.
- MIT license added.

## 2026-10-05

### Overlay

- Hints are bullet points: 1 to 4 short points (at most 40 words together), with the answer or what you can say as the first point, instead of a paragraph of prose.
- The hint with what you can say is always at the top: larger (19 pt), bold and in a colored box with an accent bar.
- A retracted hint no longer takes over that spot. It appears for about 6 seconds as a small gray line with the reason, after which the panel shrinks again.
- Earlier hints and the last utterance use a slightly larger font.
- The panel can be resized with the grip at the bottom right (three diagonal lines). The size is remembered; **Reset Overlay Size** in the 💡 menu restores it. The panel stays within the screen.
- **Met wie?** input field in the panel (outside a meeting). The report is then named, for example, `2026-10-05-104736-Finance-met-Jan Jansen.md`; without a name `…-Finance-gesprek.md`. (Since 2026-10-06: Meeting info.)
- HintMeet is an ordinary app with an icon in `~/Applications`: start it via Spotlight, Launchpad or the Dock. `app/build-app.sh` installs it there.
- **Convert Documents (kb_prep)…** in the 💡 menu: choose a source folder and project name, with the options *Convert everything again* (`--force`) and *Without OCR* (`--no-ocr`). Progress per file and per page, Stop, and afterwards the summary and the log. The window may be closed; conversion continues. The project name follows the last folder name of the source folder by default, until you change it yourself.
- The logs of Load KB and Convert Documents only contain readable lines (✓, ⚠, ✗, summary), without the progress lines for the bar.
- HintMeet has an ordinary menu bar at the top left (HintMeet, Edit, Meeting, Knowledge Base, Window, Help) and a Dock icon; the 💡 menu at the top right stays. New there: **Load KB** (⌘L). Clicking the Dock icon shows the panel. Cut and paste now also work in the *Met wie?* field.
- If a kb_prep is already running on the same knowledge base, the message says which one (since when, from the terminal or HintMeet, which source, which process) instead of "failed (code 3)". Load KB then continues with the KB as it is and warns that the documents were not updated.
- Several projects at once as knowledge base: check them in the panel, in Settings or in the 💡 menu. They are searched together; sources get the project name in front (`acme/offerte.pdf`). The report goes to the first project, with all names in the file name (`…-Finance+acme-met-….md`).
- **Load KB** button next to the knowledge base choice: updates the documents from the source folder (kb_prep), indexes the KB and loads speech recognition, with a progress bar and Stop. After that a meeting starts quickly. Stopping keeps what's done.
- Steps without their own progress show an estimate based on the previous run ("~20 s left (estimate)"); only the very first time a spinner.
- The KB's word index is saved (`.hint-meet-cache/bm25-v1.npz`): for Finance the KB loads in ~11 s instead of over a minute, and searching during a meeting is much faster.
- **Restart HintMeet** in the 💡 menu (⌘R): starts the latest build again; the chosen project stays selected, no meeting starts.
- Quitting, restarting and Stop Meeting wait until the report is done, without a time limit. Meanwhile the panel shows a spinner with the step (saving transcript, writing report) and the elapsed time, with **Abort Now** if it hangs.

### kb_prep

- New file types: `.doc` and `.odt` (via textutil), `.xls` (including "xls" exports that are really html), `.mht`/`.mhtml` web archives, and `.gif`/`.bmp` via OCR. For Finance that's over 1,400 extra files.
- HTML is converted without the content of scripts and styles; existing `.html` shadow files are therefore recreated once.
- Source files with a very long name can be converted again. The shadow file name is then shortened, with a hash appended.
- Passwords for protected PDFs in `.kbpasswords` in the source folder (see README).
- `node_modules`, hidden folders (`.git`, `.venv`) and build folders next to a project file are skipped.
- More robust with tricky files: Word files with embedded fonts or WMF/EMF images, very tall scans (OCR in strips) and JSON with comments.
- Clear messages for files that contain only zeros (like broken Dropbox conflict copies), for an `.xlsx` that is really another format, and for PDFs whose password is missing.
- A folder that can't be read keeps its existing shadow files instead of having them cleaned up.

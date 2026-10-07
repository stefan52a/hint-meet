# Changelog

What changes for the user, newest first. Technical details are in `git log`.

## 2026-10-07

### App

- **Find Documents during a meeting** searches the knowledge base the meeting already loaded, so it isn't loaded a second time (no extra memory, and instant). While the meeting is still loading, it says so.
- *Play Recording…* is now **Start with a Recorded Meeting…**.
- **Find Documents stays loaded:** closing the window no longer unloads the knowledge base, so the next search is instant. After *Load KB* or *Add Folder* it loads in the background right away. During a meeting it's paused to save memory (the meeting loads the knowledge base itself) and comes back afterwards.
- **Load KB only when needed:** the button appears only if the chosen knowledge base was never loaded (or loading was stopped), or if documents changed in the source folder or the knowledge base since the last load. HintMeet checks this in the background when you choose a project, after loading or converting, and when you switch back to HintMeet.
- **Warning the first time:** when many documents still need to be embedded (Load KB, Add Folder, Find Documents, or starting a meeting on a new knowledge base), HintMeet says that this happens only once, can take a long time, and shows the estimated duration; you can stop and continue later.
- The panel no longer shows "● hint-meet" at the top (the window title says HintMeet); outside a meeting the settings button sits at the end of the knowledge base row. The heights of transcript and hints follow the window exactly.
- **Find Documents** (button next to Load KB, or ⌘F in the Knowledge Base menu): type what you're looking for (words, an amount, a name, a topic) and get the best matching documents in the chosen knowledge base(s), each with its heading and a snippet, and *Open* or *Show in Finder*. The knowledge base loads once when the window opens (with progress per phase); after that every search is instant. Closing the window frees the memory.
- **A real window:** the HintMeet panel has a title bar with close, minimize and maximize (green button), can be resized from any edge or corner, and its content fills the window (the transcript and hints grow with it). Closing hides it; *Show Overlay*, the Dock icon or 💡 brings it back. macOS remembers its position and size. *Keep Overlay on Top* in the Window menu (on by default).
- **Progress per phase** for Load KB and Add Folder: an overall progress bar with percentage, elapsed time and Stop, and below it each phase (updating documents, loading the embedding model, reading documents, word index, embeddings, loading speech recognition) with ✓, its own progress bar or ○. The overall bar weighs each phase by how long it took last time.
- **Add Folder…** in the knowledge base menu (panel and Knowledge Base menu): point to a folder and HintMeet turns it into a knowledge base with kb_prep, with progress in the panel. The new project is selected and, in the same run, indexed and loaded (no separate *Load KB* needed). Large folders can take hours: *Stop* keeps what's done, and *Load KB* on that project continues later. Choosing the same folder again also continues; a different folder with the same name gets its own project (`-2`).
- **All languages:** the language menu now lists all 100 languages Whisper recognizes, alphabetically by English name, with *Multilingual* at the top. With the menu open, type the first letter (D for Dutch) to jump there. Hints and the report follow the chosen language; for languages other than Dutch, English, German and French the fixed texts in the report file are in English.

## 2026-10-06

### App

- In the report, hints with several points are listed as numbered items with their points indented, instead of a jumble of dashes.
- Hints and the report are written in the chosen conversation language (with Multilingual: the language of the last turns). Before, hints in an English meeting sometimes came out in Dutch.
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
- The background docs (the Jev conversation and the plan from prototype to Mac app) and the comments in `.env.example` and `config/gate.yaml` are in English; the docs have English file names.
- README shows HintMeet at work (hints during an English meeting, and Convert Documents building a knowledge base), using a fictional English demo dossier in `examples/` that you can try yourself.
- README includes an example report from the demo meeting ([docs/example-report.md](docs/example-report.md)).

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

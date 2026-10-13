# Changelog

What changes for the user, newest first. Technical details are in `git log`.

## 2026-10-13

### App

- **The knowledge base name is in every window title:** the panel (*HintMeet · Koinonia-Villages-Circles*) and the separate column windows (*Transcript · Koinonia-Villages-Circles*), so you can tell which window belongs to which knowledge base, also with two HintMeets open.
- **Run more than one HintMeet at a time** (for example two meetings): **New HintMeet Window** (⌘N) in the HintMeet menu and the 💡 menu starts another HintMeet with its own panel, meeting, project and log. The second one is called *HintMeet 2* (💡 2 in the menu bar), opens slightly offset from the first and remembers its own window positions.
- **The left column works like the hints:** live, the newest backed statement sits in the middle of the column. Scroll up or click one, and that one moves to the middle with the later ones below it. Scrolling back to the bottom goes live again.
- **Click the green ✓ in the transcript** to jump to that statement in the left column. The utterance turns green in the transcript. Clicking a card in the left column does the same and scrolls the transcript to its utterance.
- **Clearer layout.** Before a meeting, one centered card with three numbered steps: *Knowledge base* (with a *Ready* / *Not loaded* label and loading progress in one line; *Details* shows the phases), *Meeting* (with whom, language) and a large blue **Start Meeting** (or *Use a recorded meeting instead…*). During a meeting, one top bar with a blinking red **REC** and the time, the project, what HintMeet is doing, *Find* and a red **Stop**; below it three columns with the same header: title, count and their sensitivity slider. After the meeting, a banner with **Open Report with Action Items** and **New Meeting** (back to the start screen). *Find Documents*, *Settings* and *Restart HintMeet* sit in a small bar at the bottom.
- **"Listening…" pulses softly** in the meeting bar, so you can see HintMeet is listening.
- **Fewer wrong names:** a recorded voice now needs a closer match (`speakers.enroll_threshold`, 0.75), and a voice from the meeting itself wins if it matches better. On the test conversation, someone else was sometimes shown as *Stefan*; that no longer happens.
- **Train your voice in several situations:** *Settings → Your voice → Add Sample (10 s)* adds a recording instead of replacing it (up to 10 per name, e.g. headset, laptop microphone, meeting room); HintMeet compares each utterance with the best matching sample. *Forget* removes all of them.
- **Rename a speaker:** right-click a line in the transcript and choose *Rename Speaker 1…* (e.g. → *Jan*). Earlier and later utterances get the name, also in the report and in what Claude sees. Optionally *Remember this voice for next meetings*, so Jan is recognized by name next time. *Unknown* can't be renamed: it collects all replies too short to recognize, from anyone.
- **Speakers recognized by voice:** with only a microphone (or a mono recording) everyone came in as *Unknown*; HintMeet now tells voices apart, locally on your Mac: *Speaker 1*, *Speaker 2*, … and the same voice keeps its number. Record your voice once under **Settings → Your voice** (10 seconds) and you appear by name. Very short replies ("yes") keep *Unknown*. On the test conversation, mixed to one channel, every utterance of over a second was attributed to the right speaker. Settings under `speakers` in `config/gate.yaml`.
- **Change the language during a meeting:** the language menu is also in the meeting bar. Speech recognition, hints, the left column and the report follow the new language from the next utterance.
- **Columns in their own windows:** the button in a column header opens that column in a separate window that you can move and resize (for example on a second screen). Closing it, or the same button, puts it back. In the panel, the dividers between the columns can be dragged. HintMeet remembers which columns are separate and where their windows are.
- **Finishing a meeting shows its steps:** *Step 2 of 3: Saving the transcript…*, with a bar over the steps and ✓ for what's done; while the report is written, a moving bar (its duration is unknown) and **Abort**, which stops without a report (the transcript is already saved).
- **Sliders go further at *More*:** on the right every matching passage counts and the gatekeeper's minimum urgency is dropped near the top; on the left every passage counts and up to 5 passages are checked.
- **"Not loaded" right after Preload KB is fixed:** Preload updates the documents first, and those updates counted as changes after the load, so the knowledge base never showed *Ready*.
- **All three columns scroll along** when their scrollbar is at the very bottom: new utterances, new lines on the left and new hints, also while a hint or utterance is still growing. Scrolled up, a column stays where you are. Before, the transcript stopped following while you looked at an earlier hint, and growing text didn't scroll.
- **Loading progress is readable again:** lines like *Embeddings: 1792 of 4123 new chunks · ~34 s left* now wrap instead of being cut off in the middle, which dropped the total.
- Start, Stop and Open Report keep their colour also when HintMeet isn't the active app (macOS turned them grey before).
- **New left column: Backed by the knowledge base.** Next to the hints and corrections (right) and the transcript (middle), the panel now shows what was said and matches your documents: one short line per statement (for example *Purchase price € 2,100,000, payable on 1 March 2026*) with a link to the source. The utterance gets a green ✓ in the transcript. Small talk, very short replies and statements that need a correction are left out; corrections stay hints on the right.
- The column runs in the background (Claude Haiku) and never delays a hint. On a panel narrower than about 860 points it moves below the transcript. The default panel width is now 900 to fit three columns.
- Settings in `config/gate.yaml` under `confirm` (turn it off with `enabled: false`).
- **Two sensitivity sliders**, Fewer ↔ More, each on top of the column it controls. *Hint sensitivity* (right) decides how readily HintMeet gives a hint or correction. *Sensitivity* (left) decides how readily something counts as backed by the knowledge base. Both take effect from the next utterance, also during a meeting, and are remembered. The middle is the default from `config/gate.yaml`; ↺ goes back to it. The range is wide: at *More* on the right, almost every utterance with a matching passage is checked for a hint (slower and costs more); at *Fewer*, only very clear cases.
- **Also what the documents say about the topic:** when someone raises a subject or asks something the documents cover (for example *Tell me more about article 19.4*), the left column shows the key fact with its source, marked 📄 instead of ✓. Before, only verified statements appeared, so questions and topics gave nothing.
- **Left column no longer waits for the hints:** it runs for every utterance, also when a hint is shown on the right. Before, it only ran when no hint was needed, so with *Hint sensitivity* turned up it stayed empty.
- **Meeting reports are no longer part of the knowledge base.** HintMeet still writes them to `meetings/` in the project folder, but hints, the left column and Find Documents no longer search them. They repeat what was said and so matched the conversation better than the real documents: asking about *article 19.4* found only a previous test meeting instead of the regulation.
- **Restart HintMeet** button always at the bottom of the panel (same as ⌘R: picks up the latest build). When the report is ready, a blinking arrow points at **Open Report with Action Items** next to it for 5 seconds.
- **The panel comes back exactly where you left it**, with the same size, also on another screen or partly off-screen. Before, macOS sometimes pushed it back onto the screen or moved it to a different monitor at startup. Only if its title bar is on no connected screen anymore (for example an unplugged monitor) is it pulled back into view.
- **Speaker *Unknown* when it isn't known:** without system audio, the microphone picks up everyone in the room, so the transcript now says *Unknown* instead of *Stefan*. A mono recording (*Start with a Recorded Meeting…*) also says *Unknown* (was *Gesprek*). With system audio set up, your microphone is still *Stefan* and the other side *Gesprekspartner*.
- **Strict on purpose:** a ✓ means everything concrete in that utterance matches the documents. If one amount or date in it is off, or Claude isn't sure, nothing is shown. If Jev can't check the passages in time, the line is skipped instead of shown unchecked, and lines that would arrive late in a fast conversation are dropped.

### Documentation

- README describes the new panel (start steps, three columns, meeting bar, finishing steps), speaker recognition, voice samples, renaming and changing the language during a meeting, with new screenshots from the fictional demo dossier.

## 2026-10-08

### Speed and reliability

- **Transcript stays live while a hint is written:** speech recognition and the hint pipeline run separately. Before, an utterance right after a hint could wait up to 2.8 s before it appeared; now at most a few milliseconds. On the test conversation the first words of a hint now come a median of 1.9 s after the speaker stops (was 3.0 s).
- **No more stalls:** every call to Jev and Claude has a short time limit (3 s for the gatekeeper, 15 s for a hint). A call that hangs or fails costs that one hint; the meeting continues. Before, one hanging call held up the meeting for 48 s, and 14 utterances got no hint.
- **Faster end of an utterance:** an utterance counts as finished after 400 ms of silence instead of 500 ms (`audio.min_silence_ms` in `config/gate.yaml`). 300 ms would split a real meeting into 29% more pieces.
- **Multilingual is as fast as a fixed language:** HintMeet remembers each speaker's language instead of detecting it for every utterance (which took twice as long), and checks again regularly or when Whisper is unsure.

### Hints and Find Documents

- **Jev reranker:** Jev now also scores every passage found for how relevant it is (with the Jev gatekeeper). Only relevant passages go to Claude for a hint; if none is relevant, HintMeet stays silent right away. It runs at the same time as the gatekeeper; if Jev takes more than 3 seconds longer, the hint comes anyway, unfiltered.
- **Protection against hidden instructions:** passages that look like instructions to an AI ("ignore previous instructions…") instead of document content are left out of hints (when Jev is available).
- **Find Documents** shows how relevant each document is (for example *88% relevant*), best first, leaves out documents that don't really match, and says *Nothing relevant found* when nothing fits. A document with a passage that looks like instructions to an AI gets a warning.

### Documentation

- README and `.env.example` describe the gatekeeper as it actually works: Jev (default) or Claude Haiku, chosen in `config/gate.yaml`. The unused `PROVIDER` and `LAYA_URL` settings are removed from the docs.

## 2026-10-07

### App

- *Load KB* is now **Preload KB**, with a hint below it to do this well before a meeting: the first time can take hours, even days for very large folders.
- **Find Documents during a meeting** (button next to *Stop*, also with a recorded meeting) searches the knowledge base the meeting already loaded, so it isn't loaded a second time (no extra memory, and instant). While the meeting is still loading, it says so; if the meeting doesn't answer within 10 seconds, it says that too.
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

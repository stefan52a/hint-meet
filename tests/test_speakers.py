import json

import numpy as np

from hint_meet.speakers import MAX_SAMPLES, RATE, SpeakerID, enroll, forget_voice, load_voices, normalize, save_voice

STEFAN, ANNA, JAN = np.eye(3, dtype=np.float32)


def audio(voice, seconds=2.0):
    """Nep-audio: de 'stem' zit in het eerste sample, zodat de nep-afdruk hem terugvindt."""
    a = np.zeros(int(seconds * RATE), dtype=np.float32)
    a[0] = {0: 1.0, 1: 2.0, 2: 3.0}[int(np.argmax(voice))]
    return a


def fake_embed(a):
    v = {1.0: STEFAN, 2.0: ANNA, 3.0: JAN}[float(a[0])]
    return (v + 0.05).astype(np.float32) / np.linalg.norm(v + 0.05)


def test_enrolled_voice_by_name_others_numbered_and_stable():
    sid = SpeakerID(fake_embed, {"Stefan": STEFAN}, threshold=0.8)
    assert sid.identify(audio(STEFAN)) == "Stefan"
    assert sid.identify(audio(ANNA)) == "Speaker 1"
    assert sid.identify(audio(JAN)) == "Speaker 2"
    assert sid.identify(audio(ANNA)) == "Speaker 1"   # dezelfde stem houdt hetzelfde nummer
    assert sid.identify(audio(STEFAN)) == "Stefan"


def test_without_enrolled_voice_everyone_is_numbered():
    sid = SpeakerID(fake_embed, {}, threshold=0.8)
    assert [sid.identify(audio(v)) for v in (STEFAN, ANNA, STEFAN)] == ["Speaker 1", "Speaker 2", "Speaker 1"]


def test_too_short_keeps_channel_name():
    sid = SpeakerID(fake_embed, {"Stefan": STEFAN}, min_seconds=1.0)
    assert sid.identify(audio(STEFAN, seconds=0.5)) is None


def test_voices_are_saved_and_loaded(tmp_path):
    path = tmp_path / "voices.json"
    save_voice("Stefan", np.array([3.0, 4.0]), path)
    save_voice("Anna", np.array([1.0, 0.0]), path)
    voices = load_voices(path)
    assert set(voices) == {"Stefan", "Anna"} and np.allclose(voices["Stefan"], [[0.6, 0.8]])
    assert set(json.loads(path.read_text())) == {"Stefan", "Anna"}


def test_samples_are_added_capped_replaced_and_forgotten(tmp_path):
    path = tmp_path / "voices.json"
    for i in range(MAX_SAMPLES + 2):
        n = save_voice("Stefan", np.array([1.0, float(i)]), path)
    assert n == MAX_SAMPLES and load_voices(path)["Stefan"].shape == (MAX_SAMPLES, 2)   # de oudste vallen eraf
    assert save_voice("Stefan", np.array([0.0, 1.0]), path, replace=True) == 1
    forget_voice("Stefan", path)
    assert load_voices(path) == {}


def test_old_single_sample_file_still_loads(tmp_path):
    path = tmp_path / "voices.json"
    path.write_text(json.dumps({"Stefan": [0.6, 0.8]}))   # formaat van vóór meerdere afdrukken
    assert load_voices(path)["Stefan"].shape == (1, 2)


def test_best_matching_sample_counts():
    headset, laptop = np.array([1.0, 0.0], np.float32), np.array([0.0, 1.0], np.float32)
    voices = iter([laptop, headset])
    sid = SpeakerID(lambda a: next(voices), {"Stefan": np.stack([headset, laptop])}, enroll_threshold=0.75)
    assert sid.identify(audio(STEFAN)) == "Stefan"   # via de laptop
    assert sid.identify(audio(STEFAN)) == "Stefan"   # via de headset


def test_enroll_averages_voiced_parts():
    rng = np.random.default_rng(0)
    a = (rng.standard_normal(10 * RATE) * 0.1).astype(np.float32)
    calls = []
    e = enroll(a, lambda part: calls.append(len(part)) or np.array([1.0, 1.0]))
    assert len(calls) == 4 and np.allclose(e, [2 ** -0.5, 2 ** -0.5])   # 3 + 3 + 3 + 1 s


def test_recorded_voice_needs_the_stricter_threshold_and_the_best_match_wins():
    me = np.array([1.0, 0.0], np.float32)
    marieke = normalize(np.array([0.7, 0.71], np.float32))   # lijkt 0,7 op mij: niet genoeg voor mijn naam
    voices = iter([marieke, marieke, me])
    sid = SpeakerID(lambda a: next(voices), {"Stefan": me}, threshold=0.65, enroll_threshold=0.75)
    assert sid.identify(audio(STEFAN)) == "Speaker 1"
    assert sid.identify(audio(STEFAN)) == "Speaker 1"
    assert sid.identify(audio(STEFAN)) == "Stefan"



def test_a_better_matching_meeting_voice_beats_the_recorded_voice():
    me = np.array([1.0, 0.0, 0.0], np.float32)
    jan = normalize(np.array([0.8, 0.6, 0.0], np.float32))       # lijkt 0,8 op mij: boven enroll_threshold
    jan_again = normalize(np.array([0.79, 0.61, 0.0], np.float32))
    voices = iter([normalize(np.array([0.3, 0.95, 0.0], np.float32)), jan, jan_again])
    sid = SpeakerID(lambda a: next(voices), {"Stefan": me}, threshold=0.65, enroll_threshold=0.75)
    first = sid.identify(audio(STEFAN))           # een nieuwe stem: Speaker 1
    assert first == "Speaker 1"
    sid.clusters[0][0] = jan                      # Jan klonk al eerder in deze meeting
    # Jan lijkt 0,8 op mijn opgenomen stem, maar bijna 1,0 op zijn eigen stem uit de meeting: die wint
    assert sid.identify(audio(STEFAN)) == "Speaker 1"
    assert sid.identify(audio(STEFAN)) == "Speaker 1"

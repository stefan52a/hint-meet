from hint_meet.advise import limit_points, parse_reply


class Hit:
    def __init__(self, ref):
        self.chunk = type("C", (), {"ref": ref})()


def test_at_most_max_points_are_kept():
    text = "- een\n- twee\n- drie\n- vier\n- vijf"
    assert limit_points(text, 4) == "- een\n- twee\n- drie\n- vier"


def test_single_point_and_prose_untouched():
    assert limit_points("- alleen dit", 4) == "- alleen dit"
    assert limit_points("Gewone zin zonder punten.", 4) == "Gewone zin zonder punten."


def test_parse_reply_limits_points_and_keeps_sources():
    reply = "- a\n- b\n- c\n- d\n- e\nBRONNEN: 1"
    advice = parse_reply(reply, [Hit("x.md")], max_points=4)
    assert advice.text.count("- ") == 4 and advice.sources == ["x.md"]

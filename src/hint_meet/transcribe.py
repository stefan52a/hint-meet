"""Audio-capture (microfoon + systeemaudio via BlackHole) en faster-whisper-transcriptie.

Levert blokjes van 5 tot 8 seconden en houdt een rolling window van de laatste beurten bij.
"""


def stream_blocks(device: str | None = None, block_seconds: float = 6.0):
    raise NotImplementedError

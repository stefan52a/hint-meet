"""De Jev-laag: één call per transcriptblok met getypeerde vragen.

- ingrijpen?        Noul (ja-kans)
- soort moment      Choice (zie config/gate.yaml)
- KB-collectie      Choice
- urgentie          Score

PROVIDER=jev | laya | adapter bepaalt de backend; laya-serve biedt hetzelfde endpoint.
"""


def evaluate(window: list[str], config: dict) -> dict:
    raise NotImplementedError

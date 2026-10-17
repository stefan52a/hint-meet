import anthropic
import httpx
import pytest
from typesafe_sdk._core.errors import TypeSafeAuthenticationError, TypeSafeError, TypeSafeRateLimitError

from hint_meet import apierrors

REQ = httpx.Request("POST", "https://api.anthropic.com/v1/messages")


def anthropic_error(cls, status, message):
    body = {"type": "error", "error": {"type": "x", "message": message}}
    return cls(message, response=httpx.Response(status, request=REQ), body=body)


@pytest.fixture(autouse=True)
def fresh(monkeypatch):
    monkeypatch.setattr(apierrors, "_seen", set())
    monkeypatch.setattr(apierrors, "listener", None)


def test_usage_limit_and_no_credit_are_key_problems():
    e = anthropic_error(anthropic.BadRequestError, 400, "You have reached your specified API usage limits.")
    assert apierrors.key_problem(e) == ("Claude API key (ANTHROPIC_API_KEY) doesn't work: "
                                        "You have reached your specified API usage limits.")
    e = anthropic_error(anthropic.BadRequestError, 400, "Your credit balance is too low to access the Anthropic API.")
    assert "credit balance" in apierrors.key_problem(e)


def test_invalid_and_missing_keys():
    assert "invalid x-api-key" in apierrors.key_problem(
        anthropic_error(anthropic.AuthenticationError, 401, "invalid x-api-key"))
    assert apierrors.key_problem(TypeError('Could not resolve authentication method. Expected either api_key ...')) \
        == "Claude: no API key (ANTHROPIC_API_KEY). Add it in Settings (API-keys) or .env."
    ts = TypeSafeAuthenticationError(401, {"detail": "Cannot authenticate"}, httpx.Headers())
    assert apierrors.key_problem(ts).startswith("Jev API key (TYPESAFE_API_KEY) doesn't work: ")
    assert apierrors.key_problem(TypeSafeError("No API key was provided. Pass api_key ...")).startswith("Jev: no API key")


def test_transient_and_other_errors_are_not_key_problems():
    assert apierrors.key_problem(anthropic_error(anthropic.BadRequestError, 400, "max_tokens too large")) is None
    assert apierrors.key_problem(TypeSafeRateLimitError(429, None, httpx.Headers())) is None
    assert apierrors.key_problem(TimeoutError("slow")) is None
    assert apierrors.key_problem(TypeError("unsupported operand")) is None


def test_report_tells_the_listener_once_per_message():
    got = []
    apierrors.listener = got.append
    e = anthropic_error(anthropic.AuthenticationError, 401, "invalid x-api-key")
    assert apierrors.report(e) and apierrors.report(e)
    assert not apierrors.report(TimeoutError())
    assert got == ["Claude API key (ANTHROPIC_API_KEY) doesn't work: invalid x-api-key"]

"""Browser and device-login presentation state for the pinned public SDK contract.

No SDK execution, polling, storage, browser launch, cleanup proof, or usable
connection outcome. The lifecycle owner serializes calls and binds each local
intent to its real attempt/slot/configuration lineage before activation.
"""
from dataclasses import dataclass
from urllib.parse import urlsplit

from provider_rpc import CONTRACT


_LIMITS = CONTRACT["limits"]


class AccountLoginError(ValueError):
    """Closed local error; never includes SDK payloads or exception text."""


@dataclass(frozen=True, repr=False)
class DeviceInstructions:
    login_id: str
    user_code: str
    verification_url: str


@dataclass(frozen=True, repr=False)
class BrowserInstructions:
    login_id: str
    auth_url: str


def _instruction_text(value, maximum=_LIMITS["maxStringBytes"]):
    if not (
        type(value) is str
        and bool(value)
        and len(value) <= maximum
        and value == value.strip()
        and value.isprintable()
    ):
        return False
    try:
        return len(value.encode("utf-8", errors="strict")) <= maximum
    except UnicodeError:
        return False


def _validate_url(url):
    if any(character.isspace() for character in url) or "\\" in url:
        raise AccountLoginError("invalidInstructions")
    try:
        parsed = urlsplit(url)
        valid_url = (
            parsed.scheme == "https"
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and not parsed.netloc.endswith(":")
            and parsed.port != 0
        )
    except ValueError:
        valid_url = False
    if not valid_url:
        raise AccountLoginError("invalidInstructions")


def validate_browser_instructions(payload: dict) -> BrowserInstructions:
    """Project the public response within the approved presentation byte bounds.

    The owner admits SDK provenance and bounds ingress before this call.
    No browser launch, authenticated URL allowlist or expiry is inferred.
    """
    if (
        type(payload) is not dict
        or set(payload) != {"type", "loginId", "authUrl"}
        or type(payload["type"]) is not str
        or payload["type"] != "chatgpt"
        or not _instruction_text(payload["loginId"])
        or not _instruction_text(payload["authUrl"], _LIMITS["maxAuthURLBytes"])
    ):
        raise AccountLoginError("invalidInstructions")
    _validate_url(payload["authUrl"])
    return BrowserInstructions(payload["loginId"], payload["authUrl"])


def validate_device_instructions(payload: dict) -> DeviceInstructions:
    """Validate the SDK response root's JSON/alias model projection.

    Shape and bounded presentation only: the public SDK specifies no expiry,
    interval, byte bounds, code alphabet, or authenticated URL allowlist. The
    application's approved ordinary-string byte bound applies here; it is not
    an SDK fact. The caller admits provenance and bounds ingress first.
    """
    if (
        type(payload) is not dict
        or set(payload) != {"type", "loginId", "userCode", "verificationUrl"}
        or type(payload["type"]) is not str
        or payload["type"] != "chatgptDeviceCode"
        or not all(_instruction_text(payload[key]) for key in (
            "loginId", "userCode", "verificationUrl"
        ))
    ):
        raise AccountLoginError("invalidInstructions")
    url = payload["verificationUrl"]
    _validate_url(url)
    return DeviceInstructions(payload["loginId"], payload["userCode"], url)


def validate_cancel_status(payload: dict) -> str:
    """Validate an official SDK cancel projection, NOT cessation or absence."""
    if (
        type(payload) is not dict
        or set(payload) != {"status"}
        or type(payload["status"]) is not str
        or payload["status"] not in ("canceled", "notFound")
    ):
        raise AccountLoginError("invalidCancelStatus")
    return payload["status"]


def _validate_completion(payload):
    if (
        type(payload) is not dict
        or "success" not in payload
        or not set(payload) <= {"success", "loginId", "error", "onboardingEntrypoint"}
        or type(payload["success"]) is not bool
        or (payload.get("loginId") is not None
            and not _instruction_text(payload["loginId"]))
        or (payload.get("error") is not None and type(payload["error"]) is not str)
        or payload.get("onboardingEntrypoint") not in (None, "life_sciences")
        or (payload["success"] and payload.get("error") is not None)
    ):
        raise AccountLoginError("invalidCompletion")


class AccountLoginController:
    """Serialized local current-intent state, never a connection authority.

    The owner registers every returned loginId, including stale starts, before
    calling this helper. Stale delivery is ignored, not declared cleaned up.
    """

    def __init__(self, mode: str):
        if type(mode) is not str or mode not in ("chatgpt", "chatgptDeviceCode"):
            raise AccountLoginError("invalidMode")
        self._validate_instructions = (
            validate_browser_instructions if mode == "chatgpt" else validate_device_instructions
        )
        self._intent = None
        self._state = "idle"
        self._instructions = None
        self._login_id = None

    @property
    def state(self) -> str:
        return self._state

    @property
    def instructions(self) -> BrowserInstructions | DeviceInstructions | None:
        return self._instructions

    @property
    def login_id(self) -> str | None:
        """Known SDK cancel target; terminal state does not prove its closure."""
        return self._login_id

    def replace_intent(self) -> object:
        """Invalidate display and callbacks; owner retains old cleanup targets."""
        self._intent = object()
        self._state = "pending"
        self._instructions = None
        self._login_id = None
        return self._intent

    def _current(self, intent, states):
        return intent is not None and intent is self._intent and self._state in states

    def accept_instructions(self, intent: object, payload: dict) -> bool:
        if not self._current(intent, ("pending",)):
            return False
        try:
            instructions = self._validate_instructions(payload)
        except AccountLoginError:
            self.fail(intent)
            raise
        self._instructions = instructions
        self._login_id = instructions.login_id
        self._state = "waiting"
        return True

    def accept_completion(self, intent: object, payload: dict) -> bool:
        """Return a one-time auth-completed handoff, never usable/connected."""
        if not self._current(intent, ("waiting",)):
            return False
        try:
            _validate_completion(payload)
        except AccountLoginError:
            self.fail(intent)
            raise
        if payload.get("loginId") != self._login_id:
            return False
        self._instructions = None
        if not payload["success"]:
            self._state = "failed"
            return False
        self._state = "authCompleted"
        return True

    def cancel(self, intent: object) -> bool:
        """Select local cancellation once; owner must cease and clean up."""
        if not self._current(intent, ("pending", "waiting", "authCompleted")):
            return False
        self._state = "cancelled"
        self._instructions = None
        return True

    def fail(self, intent: object) -> bool:
        if not self._current(intent, ("pending", "waiting", "authCompleted")):
            return False
        self._state = "failed"
        self._instructions = None
        return True

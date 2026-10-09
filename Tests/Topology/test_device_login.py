import importlib.util
from pathlib import Path
import sys
import unittest


_SOURCE = Path(__file__).resolve().parents[2] / "ProviderAgent" / "device_login.py"
_SPEC = importlib.util.spec_from_file_location("paperlens_device_login", _SOURCE)
device = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = device
_SPEC.loader.exec_module(device)


def instructions(**changes):
    value = {
        "type": "chatgptDeviceCode",
        "loginId": "fixture-login",
        "userCode": "FIXTURE-CODE",
        "verificationUrl": "https://example.invalid/device",
    }
    value.update(changes)
    return value


def completion(**changes):
    value = {"loginId": "fixture-login", "success": True}
    value.update(changes)
    return value


class DeviceInstructionTests(unittest.TestCase):
    def assert_invalid(self, payload):
        with self.assertRaises(device.DeviceLoginError) as caught:
            device.validate_device_instructions(payload)
        self.assertEqual(str(caught.exception), "invalidInstructions")

    def test_public_device_projection_and_secret_free_repr(self):
        value = device.validate_device_instructions(instructions())
        self.assertEqual(value.login_id, "fixture-login")
        self.assertEqual(value.user_code, "FIXTURE-CODE")
        self.assertEqual(value.verification_url, "https://example.invalid/device")
        for secret in (value.login_id, value.user_code, value.verification_url):
            self.assertNotIn(secret, repr(value))
        with self.assertRaises(AttributeError):
            value.user_code = "changed"

    def test_closed_fields_and_no_invented_expiry(self):
        for field in instructions():
            value = instructions()
            del value[field]
            self.assert_invalid(value)
        for field in ("expiresAt", "interval", "authUrl", "token", "extra"):
            self.assert_invalid(instructions(**{field: "secret"}))
        for value in (None, [], "secret", True):
            self.assert_invalid(value)

    def test_instruction_types_empty_and_controls(self):
        for field in ("loginId", "userCode", "verificationUrl"):
            for value in (None, True, 1, [], "", " leading", "trailing ",
                          "line\nbreak", "tab\tcode", "nul\x00code", "bidi\u202ecode"):
                with self.subTest(field=field, value=value):
                    self.assert_invalid(instructions(**{field: value}))
        for value in ("chatgpt", "apiKey", "chatgptAuthTokens", None, 1):
            self.assert_invalid(instructions(type=value))

    def test_no_guessed_code_alphabet_or_expiry(self):
        value = device.validate_device_instructions(instructions(userCode="AB CD-123"))
        self.assertEqual(value.user_code, "AB CD-123")

    def test_unsafe_url_syntax(self):
        for url in ("http://example.invalid/device", "file:///secret", "javascript:secret",
                    "//example.invalid/device", "https:///device", "https://",
                    "https://user@example.invalid/device", "https://user:secret@example.invalid/",
                    "https://example.invalid:bad/device", "https://example.invalid:65536/",
                    "https://example.invalid:/device",
                    "https://example.invalid:0/", "https://[broken/device",
                    "https://example.invalid/a b", "https://example.invalid\\@other.invalid/"):
            with self.subTest(url=url):
                self.assert_invalid(instructions(verificationUrl=url))

    def test_cancel_status_is_exact_sdk_shape_not_cleanup_proof(self):
        for status in ("canceled", "notFound"):
            self.assertEqual(device.validate_cancel_status({"status": status}), status)
        for value in ({}, {"status": "cancelled"}, {"status": True},
                      {"status": "canceled", "absent": True}, None):
            with self.assertRaises(device.DeviceLoginError) as caught:
                device.validate_cancel_status(value)
            self.assertEqual(str(caught.exception), "invalidCancelStatus")


class DeviceIntentTests(unittest.TestCase):
    def setUp(self):
        self.controller = device.DeviceLoginController()
        self.intent = self.controller.replace_intent()

    def waiting(self):
        self.assertTrue(self.controller.accept_instructions(self.intent, instructions()))
        self.assertEqual(self.controller.state, "waiting")

    def test_instructions_are_not_auth_or_usable(self):
        self.waiting()
        self.assertEqual(self.controller.instructions.user_code, "FIXTURE-CODE")
        self.assertFalse(self.controller.accept_instructions(self.intent, instructions()))

    def test_replacement_invalidates_all_old_callbacks(self):
        self.waiting()
        old = self.intent
        self.intent = self.controller.replace_intent()
        self.assertIsNot(self.intent, old)
        self.assertIsNone(self.controller.instructions)
        self.assertIsNone(self.controller.login_id)
        self.assertFalse(self.controller.accept_completion(old, completion()))
        self.assertFalse(self.controller.accept_instructions(old, {"bad": "secret"}))
        self.assertFalse(self.controller.cancel(old))
        self.assertFalse(self.controller.fail(old))
        self.assertEqual(self.controller.state, "pending")
        self.waiting()
        self.assertTrue(self.controller.accept_completion(self.intent, completion()))

    def test_wrong_or_missing_login_cannot_complete_current_intent(self):
        self.waiting()
        for login_id in (None, "different-login"):
            self.assertFalse(self.controller.accept_completion(
                self.intent, completion(loginId=login_id)))
        self.assertFalse(self.controller.accept_completion(self.intent, {"success": True}))
        self.assertEqual(self.controller.state, "waiting")
        self.assertIsNotNone(self.controller.instructions)

    def test_completion_is_one_time_probe_handoff_only(self):
        self.waiting()
        self.assertTrue(self.controller.accept_completion(self.intent, completion(
            error=None, onboardingEntrypoint="life_sciences")))
        self.assertEqual(self.controller.state, "authCompleted")
        self.assertIsNone(self.controller.instructions)
        self.assertFalse(self.controller.accept_completion(self.intent, completion()))
        self.assertFalse(self.controller.accept_instructions(self.intent, instructions()))

    def test_failure_discards_sdk_error_without_revival(self):
        self.waiting()
        self.assertFalse(self.controller.accept_completion(self.intent, completion(
            success=False, error="private token and URL")))
        self.assertEqual(self.controller.state, "failed")
        self.assertIsNone(self.controller.instructions)
        self.assertNotIn("private token", repr(self.controller.__dict__))
        self.assertFalse(self.controller.accept_completion(self.intent, completion()))
        self.assertFalse(self.controller.cancel(self.intent))

    def test_malformed_completions_fail_closed_with_safe_reason(self):
        for payload in ({"success": 1}, completion(success="true"),
                        completion(error=42), completion(loginId=42),
                        completion(error="private secret"), completion(extra="secret"),
                        completion(onboardingEntrypoint="unknown"), [], None):
            with self.subTest(payload=payload):
                self.setUp()
                self.waiting()
                with self.assertRaises(device.DeviceLoginError) as caught:
                    self.controller.accept_completion(self.intent, payload)
                self.assertEqual(str(caught.exception), "invalidCompletion")
                self.assertEqual(self.controller.state, "failed")
                self.assertIsNone(self.controller.instructions)
                self.assertFalse(self.controller.accept_completion(self.intent, completion()))

    def test_malformed_start_selects_terminal(self):
        with self.assertRaises(device.DeviceLoginError):
            self.controller.accept_instructions(self.intent, instructions(userCode=""))
        self.assertEqual(self.controller.state, "failed")
        self.assertIsNone(self.controller.instructions)
        self.assertFalse(self.controller.accept_instructions(self.intent, instructions()))

    def test_cancel_before_instructions_does_not_resume_late_start(self):
        self.assertTrue(self.controller.cancel(self.intent))
        self.assertIsNone(self.controller.login_id)
        self.assertFalse(self.controller.accept_instructions(self.intent, instructions()))
        self.assertFalse(self.controller.accept_completion(self.intent, completion()))
        self.assertEqual(self.controller.state, "cancelled")
        self.assertIsNone(self.controller.instructions)
        # The lifecycle owner, not this local state, must cancel the late loginId.

    def test_cancel_waiting_and_after_auth_retains_target_not_display(self):
        for after_auth in (False, True):
            with self.subTest(after_auth=after_auth):
                self.setUp()
                self.waiting()
                if after_auth:
                    self.assertTrue(self.controller.accept_completion(self.intent, completion()))
                self.assertTrue(self.controller.cancel(self.intent))
                self.assertFalse(self.controller.cancel(self.intent))
                self.assertFalse(self.controller.fail(self.intent))
                self.assertEqual(self.controller.login_id, "fixture-login")
                self.assertIsNone(self.controller.instructions)
                for status in ("canceled", "notFound"):
                    device.validate_cancel_status({"status": status})
                    self.assertEqual(self.controller.state, "cancelled")
                    self.assertEqual(self.controller.login_id, "fixture-login")
                self.assertFalse(self.controller.accept_completion(self.intent, completion()))

    def test_fail_after_auth_blocks_late_success_and_clears_display(self):
        self.waiting()
        self.assertTrue(self.controller.accept_completion(self.intent, completion()))
        self.assertTrue(self.controller.fail(self.intent))
        self.assertFalse(self.controller.fail(self.intent))
        self.assertFalse(self.controller.accept_completion(self.intent, completion()))
        self.assertEqual(self.controller.state, "failed")
        self.assertIsNone(self.controller.instructions)

    def test_completion_before_start_and_foreign_tokens_are_ignored(self):
        self.assertFalse(self.controller.accept_completion(self.intent, completion()))
        for token in (None, object()):
            self.assertFalse(self.controller.accept_instructions(token, instructions()))
            self.assertFalse(self.controller.accept_completion(token, completion()))
            self.assertFalse(self.controller.cancel(token))
        self.assertEqual(self.controller.state, "pending")


if __name__ == "__main__":
    unittest.main()

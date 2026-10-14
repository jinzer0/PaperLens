import importlib.util
from pathlib import Path
import sys
import unittest


_SOURCE = Path(__file__).resolve().parents[2] / "ProviderAgent" / "account_login.py"
_SPEC = importlib.util.spec_from_file_location("paperlens_account_login", _SOURCE)
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
        with self.assertRaises(device.AccountLoginError) as caught:
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
            with self.assertRaises(device.AccountLoginError) as caught:
                device.validate_cancel_status(value)
            self.assertEqual(str(caught.exception), "invalidCancelStatus")


class DeviceIntentTests(unittest.TestCase):
    def setUp(self):
        self.controller = device.AccountLoginController("chatgptDeviceCode")
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
                with self.assertRaises(device.AccountLoginError) as caught:
                    self.controller.accept_completion(self.intent, payload)
                self.assertEqual(str(caught.exception), "invalidCompletion")
                self.assertEqual(self.controller.state, "failed")
                self.assertIsNone(self.controller.instructions)
                self.assertFalse(self.controller.accept_completion(self.intent, completion()))

    def test_malformed_start_selects_terminal(self):
        with self.assertRaises(device.AccountLoginError):
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


def browser_instructions(**changes):
    value = {"type": "chatgpt", "loginId": "fixture-login",
             "authUrl": "https://example.invalid/auth?state=fixture-private"}
    value.update(changes)
    return value


class BrowserLoginTests(unittest.TestCase):
    def test_browser_projection_is_immutable_and_does_not_print_private_values(self):
        value = device.validate_browser_instructions(browser_instructions())
        self.assertEqual(value.login_id, "fixture-login")
        self.assertEqual(value.auth_url, browser_instructions()["authUrl"])
        for private in (value.login_id, value.auth_url, "fixture-private"):
            self.assertNotIn(private, repr(value))
        with self.assertRaises(AttributeError):
            value.auth_url = "https://example.invalid/replaced"

    def test_browser_shape_rejects_other_modes_fields_types_and_missing_values(self):
        invalid = [None, [], instructions(), browser_instructions(type="apiKey")]
        for field in browser_instructions():
            value = browser_instructions()
            del value[field]
            invalid.append(value)
        for field in ("loginId", "authUrl"):
            for value in (None, True, 1, "", " leading", "trailing ", "line\nbreak", "bidi\u202evalue"):
                invalid.append(browser_instructions(**{field: value}))
        for field in ("expiresAt", "interval", "token", "userCode", "verificationUrl"):
            invalid.append(browser_instructions(**{field: "private"}))
        for payload in invalid:
            with self.subTest(payload=payload):
                with self.assertRaises(device.AccountLoginError) as caught:
                    device.validate_browser_instructions(payload)
                self.assertEqual(str(caught.exception), "invalidInstructions")

    def test_browser_url_safety_matches_device_url_safety(self):
        for url in ("http://example.invalid/auth", "file:///secret", "https:///auth",
                    "https://user:secret@example.invalid/", "https://example.invalid:0/",
                    "https://example.invalid:/", "https://example.invalid:65536/",
                    "https://[broken/auth", "https://example.invalid/a b",
                    "https://example.invalid\\@other.invalid/"):
            with self.subTest(url=url), self.assertRaises(device.AccountLoginError):
                device.validate_browser_instructions(browser_instructions(authUrl=url))

    def test_mode_is_explicit_and_cross_mode_start_fails_closed(self):
        for mode in (None, True, 1, "", "apiKey", "chatgptAuthTokens"):
            with self.assertRaises(device.AccountLoginError) as caught:
                device.AccountLoginController(mode)
            self.assertEqual(str(caught.exception), "invalidMode")
        for mode, payload in (("chatgpt", instructions()),
                              ("chatgptDeviceCode", browser_instructions())):
            controller = device.AccountLoginController(mode)
            intent = controller.replace_intent()
            with self.assertRaises(device.AccountLoginError):
                controller.accept_instructions(intent, payload)
            self.assertEqual(controller.state, "failed")
            self.assertIsNone(controller.instructions)
            self.assertIsNone(controller.login_id)

    def test_browser_completion_is_correlated_one_time_handoff_not_connection(self):
        controller = device.AccountLoginController("chatgpt")
        intent = controller.replace_intent()
        self.assertFalse(controller.accept_completion(intent, completion()))
        self.assertTrue(controller.accept_instructions(intent, browser_instructions()))
        self.assertEqual(controller.state, "waiting")
        for payload in (completion(loginId=None), completion(loginId="other")):
            self.assertFalse(controller.accept_completion(intent, payload))
            self.assertIsNotNone(controller.instructions)
        self.assertTrue(controller.accept_completion(intent, completion()))
        self.assertEqual(controller.state, "authCompleted")
        self.assertIsNone(controller.instructions)
        self.assertFalse(controller.accept_completion(intent, completion()))
        self.assertTrue(controller.cancel(intent))
        self.assertEqual(controller.login_id, "fixture-login")
        self.assertFalse(controller.accept_completion(intent, completion()))

    def test_browser_replacement_revokes_late_callbacks_without_claiming_cleanup(self):
        controller = device.AccountLoginController("chatgpt")
        old = controller.replace_intent()
        controller.accept_instructions(old, browser_instructions())
        fresh = controller.replace_intent()
        self.assertIsNone(controller.instructions)
        self.assertIsNone(controller.login_id)
        self.assertFalse(controller.accept_completion(old, completion()))
        self.assertFalse(controller.accept_instructions(old, browser_instructions()))
        self.assertFalse(controller.cancel(old))
        self.assertTrue(controller.accept_instructions(fresh, browser_instructions(loginId="fresh-login")))
        self.assertFalse(controller.accept_completion(fresh, completion()))
        self.assertTrue(controller.accept_completion(fresh, completion(loginId="fresh-login")))

    def test_browser_cancellation_and_failure_discard_private_display(self):
        for failed in (False, True):
            controller = device.AccountLoginController("chatgpt")
            intent = controller.replace_intent()
            controller.accept_instructions(intent, browser_instructions())
            if failed:
                self.assertFalse(controller.accept_completion(intent, completion(
                    success=False, error="private SDK error")))
                self.assertEqual(controller.state, "failed")
            else:
                self.assertTrue(controller.cancel(intent))
                self.assertEqual(controller.state, "cancelled")
            self.assertIsNone(controller.instructions)
            self.assertEqual(controller.login_id, "fixture-login")
            self.assertNotIn("private SDK error", repr(controller.__dict__))
            self.assertNotIn("fixture-private", repr(controller.__dict__))
            self.assertFalse(controller.accept_completion(intent, completion()))


if __name__ == "__main__":
    unittest.main()

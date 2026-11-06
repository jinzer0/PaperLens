"""OFFLINE SCRIPTED PUBLIC-CONTRACT tests, NOT official SDK execution proof.

Only private Python-object injection is used. No fake openai_codex module is
installed and production import/identity selection is never replaced by a default
fixture. Fresh OS fixtures use only newly created directories and are externally
terminated/reaped; this is not a purge or SDK closure claim.
"""
import asyncio
import ast
import importlib.util
import json
import os
from pathlib import Path
import queue
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Contracts/ProviderRPC'))
sys.path.insert(0, str(ROOT / 'ProviderAgent'))
import agent
import sdk_worker
from provider_rpc import ProtocolError, decode_frame, validate_terminal


def identity():
    return {'stageID': str(uuid.uuid4()), 'intentID': str(uuid.uuid4())}


def selector():
    return {'kind': None, 'slotID': None, 'generation': 0, 'model': None}


def request(method, params, timeout=1000):
    return {'kind': 'request', 'id': str(uuid.uuid4()), 'method': method,
            'params': params, 'timeoutMs': timeout}


class ScriptedPublicModel(SimpleNamespace):
    """Explicitly scripted public-contract object; not a generated SDK model."""
    def model_dump(self, **kwargs):
        if kwargs != {'by_alias': True, 'mode': 'json', 'exclude_none': True}:
            raise AssertionError('wrong public projection')
        return dict(self.payload)


def public_model(**fields):
    return ScriptedPublicModel(**fields)


def notification(method, payload):
    return SimpleNamespace(method=method, payload=ScriptedPublicModel(payload=payload))


def completion(thread='thread-actual', turn='turn-actual', status='completed',
               text='{"text":"PAPERLENS_OK"}', phase='final_answer', error=None,
               items_view='full', count=1):
    items = [SimpleNamespace(root=SimpleNamespace(type='agentMessage', phase=phase, text=text))
             for _ in range(count)]
    return SimpleNamespace(method='turn/completed', payload=SimpleNamespace(
        thread_id=thread, turn=SimpleNamespace(id=turn, status=status, error=error,
                                              items=items, items_view=items_view)))


class ScriptedPublicClient:
    """Scripted public method surface. Blocking calls deliberately have no timeout."""
    def __init__(self):
        self.calls = []
        self.login_notifications = queue.Queue()
        self.turn_notifications = queue.Queue()
        self.global_release = threading.Event()
        self.start_release = threading.Event()
        self.start_release.set()
        self.login_payload = {'type': 'chatgpt', 'loginId': 'actual-login',
                              'authUrl': 'https://example.invalid/auth'}
        self.cancel_payload = {'status': 'canceled'}
        self.initialize_result = SimpleNamespace(user_agent='scripted-contract')

    def initialize(self):
        self.calls.append(('initialize',))
        return self.initialize_result

    def next_notification(self):
        self.calls.append(('next_notification',))
        self.global_release.wait()
        return notification('scripted/released', {})

    def account_login_start(self, params):
        self.calls.append(('account_login_start', params))
        self.start_release.wait()
        payload = dict(self.login_payload)
        return SimpleNamespace(root=ScriptedPublicModel(
            login_id=payload.get('loginId'), payload=payload))

    def next_login_notification(self, login_id):
        self.calls.append(('next_login_notification', login_id))
        return self.login_notifications.get()

    def account_login_cancel(self, login_id):
        self.calls.append(('account_login_cancel', login_id))
        return ScriptedPublicModel(payload=self.cancel_payload)

    def thread_start(self, params):
        self.calls.append(('thread_start', params))
        return SimpleNamespace(thread=SimpleNamespace(id='thread-actual'))

    def turn_start(self, thread_id, input, params):
        self.calls.append(('turn_start', thread_id, input, params))
        return SimpleNamespace(turn=SimpleNamespace(id='turn-actual'))

    def next_turn_notification(self, turn_id):
        self.calls.append(('next_turn_notification', turn_id))
        return self.turn_notifications.get()

    def turn_interrupt(self, thread_id, turn_id):
        self.calls.append(('turn_interrupt', thread_id, turn_id))
        return SimpleNamespace()


def scripted_worker():
    owner = sdk_worker.OfficialSDKWorker()
    # Private CODE ONLY injection: no environment/argv/default factory seam.
    owner.client = ScriptedPublicClient()
    owner.models = SimpleNamespace(**{name: public_model for name in (
        'ChatgptLoginAccountParams', 'ChatgptDeviceCodeLoginAccountParams',
        'LoginAccountParams', 'ThreadStartParams', 'AskForApproval',
        'TurnStartParams', 'ReadOnlySandboxPolicy')},
        SandboxMode=SimpleNamespace(read_only='read-only'))
    owner.cwd = Path('/SCRIPTED-PUBLIC-CONTRACT-NOT-PRODUCTION')
    owner.run_id = str(uuid.uuid4())
    owner.dispatch_enabled = True
    return owner


class ScriptedDispatchTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.owner = scripted_worker()
        self.bound = identity()
        self.expected = selector()

    async def asyncTearDown(self):
        self.owner.select_unknown('scriptedFixtureTeardown')
        self.owner.client.global_release.set()
        self.owner.client.start_release.set()
        self.owner.client.login_notifications.put(notification('scripted/released', {}))
        self.owner.client.turn_notifications.put(completion())
        for reader in self.owner.readers:
            reader.join(1)
        for job in self.owner.jobs:
            job.thread.join(1)
        # The fixture does not reset owner roots or label retained objects clean.

    async def call(self, method, params=None, timeout=1, identifier=None):
        return await self.owner.dispatch(method, params or {}, request_id=identifier or str(uuid.uuid4()),
            deadline=asyncio.get_running_loop().time() + timeout)

    async def hello(self):
        return await self.call('product.hello')

    async def login(self, mode='browser'):
        await self.hello()
        if mode == 'device':
            self.owner.client.login_payload = {'type': 'chatgptDeviceCode', 'loginId': 'actual-login',
                'userCode': 'USER-CODE', 'verificationUrl': 'https://example.invalid/device'}
        return await self.call('product.loginStart', dict(self.bound, expectedSelector=self.expected,
                                                        model='bound-model', mode=mode))

    async def authenticate(self):
        await self.login()
        self.owner.client.login_notifications.put(notification('account/login/completed',
            {'loginId': 'actual-login', 'success': True}))
        for _ in range(1000):
            observed = await self.call('product.loginObserve', self.bound)
            if observed['state'] == 'authenticated':
                return observed
            await asyncio.sleep(0.001)
        self.fail('scripted completion was not observed')

    async def test_real_call_boundary_hello_and_no_fixture_initialization(self):
        with patch.object(agent, 'RuntimeProbe', side_effect=AssertionError), \
                patch.object(agent, 'Fixtures', side_effect=AssertionError), \
                patch.object(agent, 'AttemptFixtures', side_effect=AssertionError):
            server = agent.Server(mode='product', worker=self.owner)
        self.assertIsNone(server.runtime)
        self.assertIsNone(server.fixtures)
        self.assertIsNone(server.attempts)
        self.assertEqual(await self.hello(), {'major': 2, 'minor': 0, 'capabilities': ['product-v1']})
        self.assertIn(('initialize',), self.owner.client.calls)
        self.assertIs(self.owner.sdk_objects[0], self.owner.client.initialize_result)
        with self.assertRaises(ProtocolError):
            await self.hello()

    async def test_both_login_modes_project_public_instructions_not_sdk_id(self):
        for mode in ('browser', 'device'):
            if mode == 'device':
                self.owner.select_unknown('scriptedModeComplete')
                self.owner.client.global_release.set()
                self.owner.client.login_notifications.put(notification('scripted/released', {}))
                self.owner = scripted_worker()
            result = await self.login(mode)
            validate_terminal({'kind': 'result', 'id': str(uuid.uuid4()), 'result': result}, 'product.loginStart')
            self.assertNotIn('loginId', json.dumps(result))
            call = next(c for c in self.owner.client.calls if c[0] == 'account_login_start')
            self.assertEqual(call[1].root.type, 'chatgpt' if mode == 'browser' else 'chatgptDeviceCode')
            self.assertEqual(self.owner.stage.login_ids, ['actual-login'])

    async def test_completion_before_observe_is_local_authenticated_not_usable(self):
        observed = await self.authenticate()
        self.assertEqual(observed, dict(self.bound, state='authenticated'))
        self.assertFalse(self.owner.stage.probe_validated)
        with self.assertRaises(ProtocolError):
            await self.call('product.loginStart', dict(self.bound, expectedSelector=self.expected,
                                                       model='other', mode='browser'))

    async def test_exact_probe_fields_and_authoritative_completion_only(self):
        await self.authenticate()
        self.owner.client.turn_notifications.put(notification('item/agentMessage/delta', {'delta': 'PAPERLENS_OK'}))
        self.owner.client.turn_notifications.put(completion())
        result = await self.call('product.connectionTest', dict(self.bound, expectedSelector=self.expected))
        self.assertEqual(result, dict(self.bound, expectedSelector=self.expected,
                                      state='usable', text='PAPERLENS_OK'))
        thread = next(c[1] for c in self.owner.client.calls if c[0] == 'thread_start')
        self.assertEqual((thread.model, thread.cwd, thread.ephemeral),
                         ('bound-model', str(self.owner.cwd), True))
        self.assertEqual(thread.approval_policy.root, 'never')
        self.assertEqual(thread.sandbox, 'read-only')
        self.assertEqual(thread.developer_instructions, 'Reply exactly PAPERLENS_OK.')
        turn = next(c for c in self.owner.client.calls if c[0] == 'turn_start')
        self.assertEqual(turn[1:3], ('thread-actual', []))
        self.assertEqual(turn[3].input, [])
        self.assertEqual(turn[3].thread_id, 'thread-actual')
        self.assertFalse(turn[3].sandbox_policy.network_access)
        self.assertEqual(turn[3].output_schema, sdk_worker._MARKER_SCHEMA)
        with self.assertRaises(ProtocolError):
            await self.call('product.connectionTest', dict(self.bound, expectedSelector=self.expected))

    async def test_cancel_is_once_reserved_actual_call_not_cleanup(self):
        await self.login()
        result = await self.call('product.loginCancel', self.bound)
        self.assertTrue(result['accepted'])
        self.assertIn(('account_login_cancel', 'actual-login'), self.owner.client.calls)
        self.assertFalse((await self.call('product.loginCancel', self.bound))['accepted'])
        self.assertIsNotNone(self.owner.stage)
        self.assertFalse(self.owner.stage.probe_validated)

    async def test_bad_cancel_status_and_bad_login_projection_are_closed(self):
        await self.login()
        self.owner.client.cancel_payload = {'status': 'unexpected-private-SDK-text'}
        with self.assertRaises(ProtocolError) as caught:
            await self.call('product.loginCancel', self.bound)
        self.assertEqual(caught.exception.code, 'unavailable')
        self.assertEqual(self.owner.stage.login_ids, ['actual-login'])

    async def test_bad_start_projection_roots_id_and_prevents_replacement(self):
        await self.hello()
        self.owner.client.login_payload['extra'] = 'not-public-instructions'
        with self.assertRaises(ProtocolError):
            await self.call('product.loginStart', dict(self.bound, expectedSelector=self.expected,
                                                       model='bound-model', mode='browser'))
        self.assertEqual(self.owner.stage.login_ids, ['actual-login'])
        with self.assertRaises(ProtocolError):
            await self.call('product.loginStart', dict(self.bound, expectedSelector=self.expected,
                                                       model='bound-model', mode='browser'))

    async def test_stale_start_retains_actual_job_result_and_login_id(self):
        await self.hello()
        self.owner.client.start_release.clear()
        identifier = str(uuid.uuid4())
        task = asyncio.create_task(self.call('product.loginStart', dict(self.bound,
            expectedSelector=self.expected, model='bound-model', mode='browser'), identifier=identifier))
        for _ in range(1000):
            if any(c[0] == 'account_login_start' for c in self.owner.client.calls):
                break
            await asyncio.sleep(0.001)
        else:
            self.fail('scripted login request was not issued')
        self.owner.wire_terminal(identifier, 'timeout')
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        self.owner.client.start_release.set()
        for _ in range(1000):
            if self.owner.jobs[-1].completed:
                break
            await asyncio.sleep(0.001)
        self.assertEqual(self.owner.stage.login_ids, ['actual-login'])
        self.assertIsNone(self.owner.stage.instructions)
        self.assertIn(self.owner.jobs[-1], self.owner.occupied)
        self.assertIsNotNone(self.owner.sdk_objects[-1])
        self.assertEqual(self.owner.jobs[-1].terminal, 'timeout')

    async def test_sdk_jobs_three_ordinary_one_reserved_and_terminal_keeps_slot(self):
        self.owner.loop = asyncio.get_running_loop()
        release = threading.Event()
        tasks = [asyncio.create_task(self.owner._job(str(uuid.uuid4()), self.owner.loop.time() + 10,
                                                    release.wait)) for _ in range(3)]
        await asyncio.sleep(0)
        with self.assertRaises(ProtocolError) as caught:
            await self.owner._job('fourth', self.owner.loop.time() + 1, lambda: None)
        self.assertEqual(caught.exception.code, 'busy')
        reserved = asyncio.create_task(self.owner._job('reserved', self.owner.loop.time() + 10,
                                                      release.wait, reserved=True))
        await asyncio.sleep(0)
        self.assertEqual(len(self.owner.occupied), 4)
        self.owner.wire_terminal(self.owner.jobs[0].request_id, 'cancelled')
        tasks[0].cancel()
        self.assertEqual(len(self.owner.occupied), 4)
        release.set()
        await asyncio.gather(*tasks, reserved, return_exceptions=True)
        self.assertIn(self.owner.jobs[0], self.owner.occupied)

    async def test_global_return_after_stage_cancel_preserves_reserved_cancellation(self):
        notices = queue.Queue()
        second_read = threading.Event()
        cancel_entered = threading.Event()
        cancel_release = threading.Event()
        reads = []
        actual_cancel = self.owner._cancel
        task = None

        def global_read():
            reads.append(True)
            if len(reads) == 2:
                second_read.set()
            return notices.get()

        def held_cancel(identifier, stage):
            cancel_entered.set()
            cancel_release.wait()
            return actual_cancel(identifier, stage)

        async def reached(event):
            for _ in range(1000):
                if event.is_set() or self.owner.unknown:
                    break
                await asyncio.sleep(0.001)
            self.assertFalse(self.owner.unknown)
            self.assertTrue(event.is_set())

        try:
            with patch.object(self.owner.client, 'next_notification', side_effect=global_read), \
                    patch.object(self.owner, '_cancel', side_effect=held_cancel):
                await self.login()
                task = asyncio.create_task(self.call('product.loginCancel', self.bound, timeout=5))
                await reached(cancel_entered)
                self.assertTrue(self.owner.stage.stale)
                self.assertFalse(any(call[0] == 'account_login_cancel'
                                     for call in self.owner.client.calls))
                notices.put(notification('scripted/session-notice', {}))
                await reached(second_read)
                self.assertFalse(task.done())
                self.assertFalse(self.owner.retirement_requested)
                self.assertEqual(len(self.owner.notifications), 1)
                cancel_release.set()
                self.assertTrue((await task)['accepted'])
                self.assertIn(('account_login_cancel', 'actual-login'), self.owner.client.calls)
                self.assertFalse(self.owner.unknown)
        finally:
            if task is not None and not task.done():
                task.cancel()
            cancel_release.set()
            self.owner.select_unknown('scriptedGlobalReaderTeardown')
            notices.put(notification('scripted/released', {}))
            if task is not None:
                await asyncio.gather(task, return_exceptions=True)

    async def test_cleanup_requests_actual_retirement_and_no_fake_result(self):
        await self.login()
        actual_client = self.owner.client
        with patch.object(self.owner, '_send_control') as control:
            task = asyncio.create_task(self.call('product.stageRetire', dict(self.bound,
                cleanupID=str(uuid.uuid4()))))
            await asyncio.sleep(0)
            control.assert_called_once_with('revokeNeeded', code='scopeRetire')
            self.assertFalse(task.done())
            self.assertTrue(self.owner.stage.stale)
            self.assertEqual(self.owner.cleanup_requests[0][0], 'product.stageRetire')
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        self.assertIs(self.owner.client, actual_client)
        self.assertIsNone(self.owner.reap_record)

    async def test_expired_deadline_has_no_sdk_effect_and_unknown_freezes(self):
        with self.assertRaises(ProtocolError) as caught:
            await self.call('product.hello', timeout=-1)
        self.assertEqual(caught.exception.code, 'timeout')
        self.assertEqual(self.owner.client.calls, [])
        self.owner.select_unknown()
        with self.assertRaises(ProtocolError):
            await self.hello()
        self.assertEqual(self.owner.client.calls, [])

    async def test_wrong_scope_selector_and_completion_cannot_activate(self):
        await self.login()
        self.owner.client.login_notifications.put(notification('account/login/completed',
            {'loginId': 'not-the-actual-login', 'success': True}))
        await asyncio.sleep(0.01)
        self.assertEqual((await self.call('product.loginObserve', self.bound))['state'], 'pending')
        with self.assertRaises(ProtocolError):
            await self.call('product.loginObserve', identity())
        changed = dict(self.expected, generation=1)
        with self.assertRaises(ProtocolError):
            await self.call('product.connectionTest', dict(self.bound, expectedSelector=changed))

    async def test_probe_cancel_uses_known_actual_turn_on_reserved_lane(self):
        await self.authenticate()
        task = asyncio.create_task(self.call('product.connectionTest',
            dict(self.bound, expectedSelector=self.expected)))
        for _ in range(1000):
            if self.owner.stage.turn_ids:
                break
            await asyncio.sleep(0.001)
        else:
            self.fail('scripted turn request was not issued')
        self.assertTrue((await self.call('product.loginCancel', self.bound))['accepted'])
        self.assertIn(('turn_interrupt', 'thread-actual', 'turn-actual'), self.owner.client.calls)
        self.owner.client.turn_notifications.put(completion())
        with self.assertRaises(ProtocolError):
            await task
        self.assertFalse(self.owner.stage.probe_validated)

    async def _held_result_loses_authority(self, probe, action):
        if probe:
            await self.authenticate()
            self.owner.client.turn_notifications.put(completion())
            method = 'product.connectionTest'
            params = dict(self.bound, expectedSelector=self.expected)
        else:
            await self.hello()
            method = 'product.loginStart'
            params = dict(self.bound, expectedSelector=self.expected, model='bound-model', mode='browser')
        identifier = str(uuid.uuid4())
        loop = asyncio.get_running_loop()
        original_delivery = loop.call_soon_threadsafe
        held = []
        ready = asyncio.Event()
        def delivery(callback, *args, **kwargs):
            if (getattr(callback, '__name__', None) == 'completed'
                    and any(job.request_id == identifier and job.thread is threading.current_thread()
                            for job in self.owner.jobs)):
                held.append((callback, args))
                original_delivery(ready.set)
                return
            return original_delivery(callback, *args, **kwargs)
        retirement = None
        with patch.object(loop, 'call_soon_threadsafe', side_effect=delivery), \
                patch.object(self.owner, '_send_control') as control:
            task = asyncio.create_task(self.call(method, params, timeout=10, identifier=identifier))
            try:
                await asyncio.wait_for(ready.wait(), 2)
                job = next(job for job in self.owner.jobs if job.request_id == identifier)
                self.assertTrue(job.completed)
                self.assertFalse(job.future.done())
                self.assertIsNotNone(job.result)
                self.assertFalse(self.owner.stage.probe_validated)
                if action == 'cancel':
                    self.assertTrue((await self.call('product.loginCancel', self.bound))['accepted'])
                elif action == 'revoke':
                    self.owner._control({'v': 2, 'runID': self.owner.run_id, 'op': 'revoke',
                                         'retirementID': str(uuid.uuid4())})
                else:
                    retirement = asyncio.create_task(self.call('product.stageRetire',
                        dict(self.bound, cleanupID=str(uuid.uuid4()))))
                    await asyncio.sleep(0)
                    control.assert_called_once_with('revokeNeeded', code='scopeRetire')
                for callback, args in held:
                    callback(*args)
                with self.assertRaises(ProtocolError):
                    await task
                self.assertIn(job, self.owner.jobs)
                self.assertIn(job, self.owner.occupied)
                self.assertIsNotNone(job.result)
                self.assertFalse(self.owner.stage.probe_validated)
                self.assertEqual(self.owner.stage.login_ids, ['actual-login'])
                if probe:
                    self.assertEqual(self.owner.stage.turn_ids, ['turn-actual'])
            finally:
                task.cancel()
                if retirement is not None:
                    retirement.cancel()
                await asyncio.gather(task, *([retirement] if retirement is not None else []),
                                     return_exceptions=True)

    async def test_completed_login_delivery_rejected_after_cancel(self):
        await self._held_result_loses_authority(False, 'cancel')

    async def test_completed_login_delivery_rejected_after_revoke(self):
        await self._held_result_loses_authority(False, 'revoke')

    async def test_completed_login_delivery_rejected_after_matched_retirement(self):
        await self._held_result_loses_authority(False, 'retire')

    async def test_completed_probe_delivery_rejected_after_cancel(self):
        await self._held_result_loses_authority(True, 'cancel')

    async def test_completed_probe_delivery_rejected_after_revoke(self):
        await self._held_result_loses_authority(True, 'revoke')

    async def test_completed_probe_delivery_rejected_after_matched_retirement(self):
        await self._held_result_loses_authority(True, 'retire')

    async def _cancel_before_admission(self, probe):
        if probe:
            await self.authenticate()
            method, target = 'product.connectionTest', 'turn_start'
            params = dict(self.bound, expectedSelector=self.expected)
        else:
            await self.hello()
            method, target = 'product.loginStart', 'account_login_start'
            params = dict(self.bound, expectedSelector=self.expected, model='bound-model', mode='browser')
        ready = asyncio.Event()
        release = threading.Event()
        loop = asyncio.get_running_loop()
        original_call = self.owner._call
        def before_admission(request_id, function, *args, **kwargs):
            if function.__name__ == target:
                loop.call_soon_threadsafe(ready.set)
                release.wait()
            return original_call(request_id, function, *args, **kwargs)
        with patch.object(self.owner, '_call', side_effect=before_admission):
            task = asyncio.create_task(self.call(method, params, timeout=10))
            try:
                await asyncio.wait_for(ready.wait(), 2)
                self.assertTrue((await self.call('product.loginCancel', self.bound))['accepted'])
                release.set()
                with self.assertRaises(ProtocolError):
                    await task
                self.assertFalse(any(call[0] == target for call in self.owner.client.calls))
                self.assertFalse(self.owner.stage.probe_validated)
                if probe:
                    self.assertIn(('account_login_cancel', 'actual-login'), self.owner.client.calls)
                    self.assertEqual(self.owner.stage.thread_ids, ['thread-actual'])
                    self.assertEqual(self.owner.stage.turn_ids, [])
                else:
                    self.assertEqual(self.owner.stage.login_ids, [])
                self.assertTrue(any(job.completed and job.failed for job in self.owner.occupied))
            finally:
                release.set()
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_cancel_before_scheduled_login_admission(self):
        await self._cancel_before_admission(False)

    async def test_cancel_before_turn_admission(self):
        await self._cancel_before_admission(True)

    async def test_cancelled_stage_cannot_admit_notification_reads(self):
        await self.login()
        await self.call('product.loginCancel', self.bound)
        effect = Mock(side_effect=AssertionError('stale notification effect'))
        with self.assertRaises(ProtocolError):
            self.owner._notification(effect, stage=self.owner.stage)
        effect.assert_not_called()

    async def _paper_purge_first_has_no_effects(self, probe):
        pending = None
        if probe:
            await self.authenticate()
            pending = asyncio.create_task(self.call('product.connectionTest',
                dict(self.bound, expectedSelector=self.expected), timeout=10))
            for _ in range(1000):
                if any(call[0] == 'next_turn_notification' for call in self.owner.client.calls):
                    break
                await asyncio.sleep(0.001)
            else:
                self.fail('scripted probe reader was not admitted')
        else:
            await self.login()
            for _ in range(1000):
                if any(call[0] == 'next_login_notification' for call in self.owner.client.calls):
                    break
                await asyncio.sleep(0.001)
            else:
                self.fail('scripted login reader was not admitted')
        stage = self.owner.stage
        state = stage.controller.state
        calls = list(self.owner.client.calls)
        jobs = list(self.owner.jobs)
        readers = list(self.owner.readers)
        with patch.object(self.owner, '_send_control') as control:
            with self.assertRaises(ProtocolError) as caught:
                await self.call('product.paperPurge', {'cleanupID': str(uuid.uuid4()),
                    'paperID': str(uuid.uuid4()), 'generation': 1, 'correlationID': str(uuid.uuid4())})
            self.assertEqual(caught.exception.code, 'invalidParams')
            control.assert_not_called()
        self.assertIs(self.owner.stage, stage)
        self.assertEqual(stage.controller.state, state)
        self.assertFalse(stage.stale)
        self.assertFalse(stage.cancel_selected)
        self.assertFalse(self.owner.retirement_requested)
        self.assertFalse(self.owner.unknown)
        self.assertIsNone(self.owner.retirement_id)
        self.assertEqual(self.owner.cleanup_requests, [])
        self.assertEqual(self.owner.control_output, bytearray())
        self.assertEqual(self.owner.client.calls, calls)
        self.assertEqual(self.owner.jobs, jobs)
        self.assertEqual(self.owner.readers, readers)
        if pending is not None:
            self.owner.client.turn_notifications.put(completion())
            self.assertEqual((await pending)['state'], 'usable')
            self.assertTrue(stage.probe_validated)
        else:
            self.assertEqual((await self.call('product.loginObserve', self.bound))['state'], 'pending')

    async def test_paper_purge_first_during_healthy_login_has_no_effects(self):
        await self._paper_purge_first_has_no_effects(False)

    async def test_paper_purge_first_during_healthy_probe_has_no_effects(self):
        await self._paper_purge_first_has_no_effects(True)

    async def test_server_cancel_before_unowned_paper_dispatch_cannot_stale_stage(self):
        await self.login()
        for _ in range(1000):
            if any(call[0] == 'next_login_notification' for call in self.owner.client.calls):
                break
            await asyncio.sleep(0.001)
        else:
            self.fail('scripted login reader was not admitted')
        server = agent.Server(mode='product', worker=self.owner)
        server.ready = True
        stage = self.owner.stage
        state = stage.controller.state
        jobs = list(self.owner.jobs)
        calls = list(self.owner.client.calls)
        purge = request('product.paperPurge', {'cleanupID': str(uuid.uuid4()),
            'paperID': str(uuid.uuid4()), 'generation': 1, 'correlationID': str(uuid.uuid4())})
        with patch.object(self.owner, '_send_control') as control, \
                patch.object(self.owner, 'dispatch', wraps=self.owner.dispatch) as dispatch:
            server.accept(purge)
            scheduled = server.pending[purge['id']].task
            # No yield: generic cancellation wins before execute/dispatch starts.
            server.accept(request('cancel', {'targetID': purge['id']}))
            self.assertTrue(scheduled.cancelling())
            await asyncio.gather(scheduled, return_exceptions=True)
            dispatch.assert_not_called()
            control.assert_not_called()
        self.assertEqual(self.owner.wire_terminals[purge['id']], 'cancelled')
        self.assertNotIn(purge['id'], server.pending)
        self.assertIs(self.owner.stage, stage)
        self.assertEqual(stage.controller.state, state)
        self.assertFalse(stage.stale)
        self.assertFalse(stage.cancel_selected)
        self.assertEqual(self.owner.cleanup_requests, [])
        self.assertFalse(self.owner.retirement_requested)
        self.assertIsNone(self.owner.retirement_id)
        self.assertEqual(self.owner.control_output, bytearray())
        self.assertEqual(self.owner.jobs, jobs)
        self.assertEqual(self.owner.client.calls, calls)

    async def test_unbound_and_hello_terminals_do_not_invalidate_current_stage(self):
        await self.login()
        stage = self.owner.stage
        state = stage.controller.state
        hello_job = self.owner.jobs[0]
        self.assertIsNone(hello_job.stage)
        for identifier in ('unstarted', 'wrong-stage', 'observe-only', hello_job.request_id):
            self.owner.wire_terminal(identifier, 'timeout')
            self.assertEqual(self.owner.wire_terminals[identifier], 'timeout')
            self.assertFalse(stage.stale)
            self.assertEqual(stage.controller.state, state)
        self.assertEqual(hello_job.terminal, 'timeout')
        self.assertIs(self.owner.jobs[1].stage, stage)
        self.owner.wire_terminal(self.owner.jobs[1].request_id, 'cancelled')
        self.assertTrue(stage.stale)
        self.assertEqual(self.owner.jobs[1].terminal, 'cancelled')
        self.assertIn(self.owner.jobs[1], self.owner.jobs)

    async def test_sdk_thread_expiry_refuses_work_without_selecting_stage_terminal(self):
        await self.login()
        stage = self.owner.stage
        state = stage.controller.state
        job = self.owner.jobs[1]
        loop = asyncio.get_running_loop()
        self.owner.request_deadlines[job.request_id] = loop.time() - 1
        ready = asyncio.Event()
        errors = []
        effect = Mock(side_effect=AssertionError('expired SDK effect'))
        def expired_call():
            try:
                self.owner._call(job.request_id, effect, stage=stage)
            except BaseException as error:
                errors.append(error)
            finally:
                loop.call_soon_threadsafe(ready.set)
        thread = threading.Thread(target=expired_call, daemon=True)
        thread.start()
        await asyncio.wait_for(ready.wait(), 2)
        thread.join(1)
        effect.assert_not_called()
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], ProtocolError)
        self.assertEqual(errors[0].code, 'timeout')
        self.assertNotIn(job.request_id, self.owner.wire_terminals)
        self.assertIsNone(job.terminal)
        self.assertFalse(stage.stale)
        self.assertEqual(stage.controller.state, state)
        # The event loop, not the SDK thread, now selects the actual terminal.
        with self.assertRaises(ProtocolError) as caught:
            self.owner._check(job.request_id)
        self.assertEqual(caught.exception.code, 'timeout')
        self.assertEqual(self.owner.wire_terminals[job.request_id], 'timeout')
        self.assertEqual(job.terminal, 'timeout')
        self.assertTrue(stage.stale)

    async def test_startup_cleanup_requires_actual_selector_and_requests_retirement(self):
        await self.login()
        with self.assertRaises(ProtocolError):
            await self.call('product.startupCleanup', {'cleanupID': str(uuid.uuid4()),
                'expectedSelector': dict(self.expected, model='different')})
        self.assertEqual(self.owner.cleanup_requests, [])
        self.assertFalse(self.owner.stage.stale)
        params = {'cleanupID': str(uuid.uuid4()), 'expectedSelector': self.expected}
        with patch.object(self.owner, '_send_control') as control:
            task = asyncio.create_task(self.call('product.startupCleanup', params))
            await asyncio.sleep(0)
            self.assertFalse(task.done())
            self.assertEqual(self.owner.cleanup_requests, [('product.startupCleanup', params)])
            control.assert_called_once_with('revokeNeeded', code='scopeRetire')
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)


class LifecycleContractTests(unittest.TestCase):
    def test_first_retirement_identity_and_actual_helper_interface_no_sdk_closure_inference(self):
        owner = scripted_worker()
        owner.run_id = str(uuid.uuid4())
        owner.startup_deadline_ns = time.monotonic_ns() + 5_000_000_000
        identity = str(uuid.uuid4())
        revoke = {'v': 2, 'runID': owner.run_id, 'op': 'revoke', 'retirementID': identity}
        owner._control(revoke)
        owner._control(revoke)
        with self.assertRaises(ProtocolError):
            owner._control(dict(revoke, retirementID=str(uuid.uuid4())))
        with self.assertRaises(ProtocolError):
            owner._control({'v': 1, 'runID': owner.run_id, 'op': 'revoke',
                            'deadlineNs': time.monotonic_ns() + 250_000_000})
        self.assertEqual(owner.retirement_id, identity)
        # SCRIPTED helper receipt tests only call ownership, not real OS reaping.
        receipt = SimpleNamespace(wait_status=0, retirement_id=identity)
        entered, release = threading.Event(), threading.Event()

        def delayed_reap(actual):
            self.assertEqual(actual, identity)
            entered.set()
            if not release.wait(2):
                raise RuntimeError('scripted reaper was not released')
            return receipt

        owner.broker = SimpleNamespace(wait_direct_child=Mock(side_effect=delayed_reap))
        owner.rendezvous = SimpleNamespace(retire=Mock())
        actual_client = owner.client
        with patch.object(owner, '_send_control') as control:
            reap = dict(revoke, op='reapBroker')
            owner._control(reap)
            try:
                self.assertTrue(entered.wait(1))
                self.assertTrue(owner.retirement_requested)
                self.assertFalse(owner.unknown)
                control.assert_not_called()
                owner.rendezvous.retire.assert_not_called()
                with patch.object(sdk_worker.time, 'monotonic_ns',
                                  return_value=owner.startup_deadline_ns + 60_000_000_000):
                    owner._control(revoke)
                    owner._control(reap)
                    self.assertFalse(owner.unknown)
                owner.broker.wait_direct_child.assert_called_once_with(identity)
            finally:
                release.set()
                owner.retirement_thread.join(3)
            self.assertFalse(owner.retirement_thread.is_alive())
            owner.rendezvous.retire.assert_called_once_with(identity)
            control.assert_called_once_with('brokerReaped', retirementID=identity, waitStatus=0)
        self.assertTrue(owner.unknown)
        self.assertEqual(owner.reason, 'sdkClosureUnproven')
        self.assertIs(owner.client, actual_client)
        self.assertIs(owner.reap_record, receipt)

    def test_start_attempt_is_consumed_before_import_constructor_or_start_failure(self):
        for failure in ('module', 'constructor', 'start'):
            with self.subTest(failure=failure):
                owner = sdk_worker.OfficialSDKWorker()
                owner.environment_replaced = True
                owner.fds['cwd'] = 123  # Never accessed: rendezvous is explicitly mocked.
                owner.cwd = Path('/SCRIPTED-NOT-AN-SDK-HOME')
                owner.python, owner.agent = Path('/SCRIPTED/python'), Path('/SCRIPTED/agent.py')
                owner.run_id = str(uuid.uuid4())
                owner.startup_deadline_ns = time.monotonic_ns() + 5_000_000_000
                client = SimpleNamespace(start=Mock(side_effect=RuntimeError('start')),
                                         close=Mock(side_effect=AssertionError('must not close')))
                public = SimpleNamespace(CodexConfig=Mock(side_effect=lambda **kw: SimpleNamespace(**kw)),
                    CodexClient=Mock(side_effect=RuntimeError('constructor')) if failure == 'constructor'
                    else Mock(return_value=client))
                modules = {'openai_codex': SimpleNamespace(__version__='0.160.0'),
                           'openai_codex.client': public,
                           'openai_codex.generated.v2_all': SimpleNamespace()}
                def load(name):
                    self.assertTrue(owner.sdk_start_attempted)
                    if failure == 'module': raise RuntimeError('module')
                    return modules[name]
                with patch.object(owner, '_sdk_module', side_effect=load) as module, \
                        patch('broker_control.open_worker_rendezvous') as rendezvous:
                    with self.assertRaises(RuntimeError):
                        owner.start()
                    self.assertTrue(owner.sdk_start_attempted)
                    counts = (module.call_count, rendezvous.call_count, public.CodexClient.call_count)
                    with self.assertRaises(ProtocolError):
                        owner.start()
                    self.assertEqual(counts, (module.call_count, rendezvous.call_count,
                                             public.CodexClient.call_count))
                    client.close.assert_not_called()
                    if failure == 'start':
                        client.start.assert_called_once_with()
                        config = public.CodexConfig.call_args.kwargs
                        self.assertEqual(config['launch_args_override'],
                            ('/SCRIPTED/python', '-I', '-B', '/SCRIPTED/agent.py', '--native-broker'))

    def test_concurrent_start_cannot_enter_public_constructor_twice(self):
        owner = sdk_worker.OfficialSDKWorker()
        owner.environment_replaced = True
        entered, release = threading.Event(), threading.Event()
        errors = []
        def module(_):
            entered.set()
            if not release.wait(2): raise RuntimeError('fixture wait')
            raise RuntimeError('scripted module failure')
        def first():
            try: owner.start()
            except RuntimeError as error: errors.append(error)
        with patch.object(owner, '_sdk_module', side_effect=module) as load:
            thread = threading.Thread(target=first)
            thread.start()
            try:
                self.assertTrue(entered.wait(1))
                with self.assertRaises(ProtocolError): owner.start()
                self.assertEqual(load.call_count, 1)
            finally:
                release.set()
                thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(len(errors), 1)
            self.assertTrue(owner.sdk_start_attempted)


class MarkerContractTests(unittest.TestCase):
    def test_rejects_failed_interrupted_partial_mismatched_and_invalid_markers(self):
        invalid = [dict(status='failed'), dict(status='interrupted'), dict(status='inProgress'),
                   dict(thread='other'), dict(turn='other'), dict(error=SimpleNamespace()),
                   dict(items_view='partial'), dict(count=0), dict(count=2), dict(phase='commentary'),
                   dict(text='PAPERLENS_OK'), dict(text='{"text":"PAPERLENS_OK","extra":1}'),
                   dict(text='{"text":"wrong","text":"PAPERLENS_OK"}'),
                   dict(text='["PAPERLENS_OK"]')]
        for values in invalid:
            with self.subTest(values=values):
                self.assertFalse(sdk_worker.OfficialSDKWorker._valid_marker(
                    completion(**values).payload, 'thread-actual', 'turn-actual'))
        self.assertTrue(sdk_worker.OfficialSDKWorker._valid_marker(
            completion().payload, 'thread-actual', 'turn-actual'))

    def test_unexpected_approval_raises_not_default_accept(self):
        with self.assertRaises(sdk_worker.ClosedApproval):
            sdk_worker._deny_approval('unexpected', {})


class ServerProductModeTests(unittest.IsolatedAsyncioTestCase):
    async def test_pending_hello_not_ready_and_duplicate_refused(self):
        owner = scripted_worker()
        server = agent.Server(mode='product', worker=owner)
        server.started = asyncio.get_running_loop().time()
        gate = asyncio.Event()
        original_dispatch = owner.dispatch
        async def delayed(*args, **kwargs):
            await gate.wait()
            return await original_dispatch(*args, **kwargs)
        hello = {'major': 2, 'minor': 0, 'capabilities': ['product-v1']}
        with patch.object(owner, 'dispatch', side_effect=delayed):
            first = request('product.hello', hello)
            server.accept(first)
            self.assertFalse(server.ready)
            duplicate = request('product.hello', hello)
            server.accept(duplicate)
            _, frame = server.outgoing.get_nowait()
            self.assertEqual(decode_frame(frame)['code'], 'invalidParams')
            server.outgoing.task_done()
            gate.set()
            await server.pending[first['id']].task
        self.assertTrue(server.ready)
        owner.select_unknown()
        owner.client.global_release.set()
        for reader in owner.readers:
            reader.join(1)

    async def test_wire_terminal_precedes_task_cancellation_and_retains_unknown_pending(self):
        owner = scripted_worker()
        server = agent.Server(mode='product', worker=owner)
        record = agent.Pending('product.loginStart')
        identifier = str(uuid.uuid4())
        record.task = asyncio.create_task(asyncio.Event().wait())
        server.pending[identifier] = record
        with patch.object(owner, 'wire_terminal', wraps=owner.wire_terminal) as terminal:
            self.assertTrue(server.terminate(identifier, 'timeout'))
            terminal.assert_called_once_with(identifier, 'timeout')
            self.assertTrue(record.task.cancelling())
        await asyncio.gather(record.task, return_exceptions=True)
        server.pending['retained'] = agent.Pending('product.stageRetire')
        owner.select_unknown()
        self.assertFalse(server.terminate('retained', 'timeout'))
        self.assertIn('retained', server.pending)


class SourceContractTests(unittest.TestCase):
    def test_production_source_uses_only_public_sdk_ownership_and_exact_launch(self):
        source = (ROOT / 'ProviderAgent/sdk_worker.py').read_text()
        tree = ast.parse(source)
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
        attributes = [node.func.attr for node in calls if isinstance(node.func, ast.Attribute)]
        self.assertNotIn('close', attributes)
        self.assertNotIn('_proc', source)
        self.assertNotIn('subprocess', source)
        self.assertNotIn('asyncio.run(', source)
        self.assertIn("'--native-broker'", source)
        self.assertIn("launch_args_override=(str(self.python), '-I', '-B', str(self.agent)", source)
        self.assertIn("sdk.__version__ != '0.160.0'", source)
        self.assertIn("self.rendezvous = open_worker_rendezvous(self.fds['cwd']", source)
        self.assertLess(source.index('self.client = public.CodexClient'), source.index('self.client.start()'))
        self.assertLess(source.index('self.sdk_start_attempted = True'),
                        source.index('self.client = public.CodexClient'))
        client_starts = [node for node in calls if isinstance(node.func, ast.Attribute)
                         and node.func.attr == 'start' and isinstance(node.func.value, ast.Attribute)
                         and node.func.value.attr == 'client']
        self.assertEqual(len(client_starts), 1)
        for node in calls:
            if isinstance(node.func, ast.Attribute) and node.func.attr in (
                    'initialize', 'next_notification', 'next_login_notification',
                    'next_turn_notification', 'account_login_start', 'account_login_cancel',
                    'thread_start', 'turn_start', 'turn_interrupt'):
                self.assertNotIn('timeout', [argument.arg for argument in node.keywords])
        self.assertIn('self.parent.pid != os.getppid()', source)
        self.assertNotIn("os.dup(6)", source)
        self.assertNotIn("/ 'home'", source)

    def test_exact_worker_entry_preserves_other_modes(self):
        with patch.object(sys, 'argv', ['agent.py', '--official-sdk-worker']), \
                patch.object(sdk_worker, 'worker_main', side_effect=SystemExit) as role:
            with self.assertRaises(SystemExit):
                agent.main()
            role.assert_called_once_with(lifecycle_fd=5)
        with patch.object(sys, 'argv', ['agent.py', '--official-sdk-worker', 'extra']), \
                patch.object(sdk_worker, 'worker_main') as role, \
                patch.object(agent.os, '_exit', side_effect=SystemExit):
            with self.assertRaises(SystemExit):
                agent.main()
            role.assert_not_called()
        with patch.object(agent, 'RuntimeProbe') as runtime, \
                patch.object(agent, 'Fixtures') as fixtures, \
                patch.object(agent, 'AttemptFixtures') as attempts:
            agent.Server(mode='topology')
            runtime.assert_called_once()
            fixtures.assert_called_once()
            attempts.assert_called_once()

    def test_import_is_resource_pure_in_a_fresh_process(self):
        script = r'''
import asyncio, builtins, ctypes, importlib.util, os, socket, subprocess, sys, threading
from pathlib import Path
source = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('pure_sdk_worker', source)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
def forbidden(*a, **k): raise AssertionError('import acquired resource')
builtins.open = forbidden
os.open = forbidden
ctypes.CDLL = forbidden
socket.socket = forbidden
threading.Thread.start = forbidden
subprocess.Popen = forbidden
spec.loader.exec_module(module)
assert not any(name.startswith('openai_codex') for name in sys.modules)
assert module._ROOTS == []
'''
        result = subprocess.run([sys.executable, '-I', '-B', '-c', script,
            str(ROOT / 'ProviderAgent/sdk_worker.py')], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_fresh_missing_fd5_refuses_before_sdk_import(self):
        script = r'''
import importlib.util, os, signal, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'Contracts/ProviderRPC'))
sys.path.insert(0, str(Path(sys.argv[1]) / 'ProviderAgent'))
import sdk_worker
try: os.close(5)
except OSError: pass
owner = sdk_worker.OfficialSDKWorker()
try:
    owner.capture(5)
except BaseException:
    owner.select_unknown()
    assert not any(name.startswith('openai_codex') for name in sys.modules)
    assert sdk_worker._ROOTS[-1] is owner and owner.unknown
    os.write(1, b'REFUSED_BEFORE_SDK\n')
    while True: signal.pause()
raise AssertionError('missing FD5 admitted')
'''
        child = subprocess.Popen([sys.executable, '-I', '-B', '-c', script, str(ROOT)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            readable, _, _ = select.select([child.stdout], [], [], 10)
            self.assertTrue(readable)
            self.assertEqual(child.stdout.readline(), b'REFUSED_BEFORE_SDK\n')
            self.assertIsNone(child.poll())
        finally:
            child.kill()
            child.communicate(timeout=10)

    @unittest.skipUnless(sys.platform == 'darwin', 'actual Darwin kernel peer/ACL fixture')
    def test_fresh_namespace_and_source_package_refusal_before_sdk_import(self):
        script = r'''
import os, signal, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'Contracts/ProviderRPC'))
sys.path.insert(0, str(Path(sys.argv[1]) / 'ProviderAgent'))
import sdk_worker
inherited = int(sys.argv[2])
if inherited != 5:
    os.dup2(inherited, 5)
    os.close(inherited)
owner = sdk_worker.OfficialSDKWorker()
try:
    owner.capture(5)
except BaseException:
    owner.select_unknown()
    assert not any(name.startswith('openai_codex') for name in sys.modules)
    assert owner.client is None and owner.unknown
    os.write(1, b'REFUSED_BEFORE_SDK\n')
    while True: signal.pause()
raise AssertionError('unpackaged source or missing namespace admitted')
'''
        for complete_namespace in (False, True):
            with self.subTest(complete_namespace=complete_namespace), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                root.chmod(0o700)
                if complete_namespace:
                    for name in ('codex', 'tmp', 'work'):
                        (root / name).mkdir(mode=0o700)
                parent_socket, child_socket = socket.socketpair()
                environment = dict(os.environ,
                    PAPERLENS_BROKER_RUN_ID=str(uuid.uuid4()),
                    PAPERLENS_BROKER_START_DEADLINE_NS=str(time.monotonic_ns() + 10_000_000_000))
                child = subprocess.Popen([sys.executable, '-I', '-B', '-c', script, str(ROOT),
                    str(child_socket.fileno())], cwd=root, env=environment,
                    pass_fds=(child_socket.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                child_socket.close()
                try:
                    readable, _, _ = select.select([child.stdout], [], [], 10)
                    self.assertTrue(readable)
                    self.assertEqual(child.stdout.readline(), b'REFUSED_BEFORE_SDK\n')
                    self.assertIsNone(child.poll())
                finally:
                    child.kill()
                    child.communicate(timeout=10)
                    parent_socket.close()


if __name__ == '__main__':
    unittest.main()

"""Runnable checks for shared transport glue: python3 -m unittest shared/test_adapters.py."""
import importlib.util
import json
import os
import sys
import threading
import tempfile
import contextlib
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


hook = module('hook', Path(__file__).with_name('git-hook.py'))
ssh = module('ssh_adapter', Path(__file__).with_name('ssh.py'))


class TransportChecks(unittest.TestCase):
    def test_hook_preserves_binary_object_identifiers_and_rejects_malformed_input(self):
        old, new = '0' * 40, 'a' * 40
        self.assertEqual(hook.updates_from([f'{old} {new} refs/heads/trunk']), [{'old': old, 'new': new, 'ref': 'refs/heads/trunk'}])
        for value in ['bad', f'{old} nope refs/heads/main', f'{old} {new} ../../HEAD', f'{old} {new} refs/heads/\x00']:
            with self.assertRaises(ValueError):
                hook.updates_from([value])
        with self.assertRaises(ValueError):
            hook.updates_from([f'{old} {new} refs/heads/x'] * 2049)

    def test_ssh_rejects_untrusted_command_and_revokes_token(self):
        calls = []
        def fake_call(path, payload=None, token=None):
            calls.append((path, payload, token))
            return {'token': 'temporary', 'operation': 'sh', 'repository_path': '/data/repos/1.git'}
        with patch.object(ssh, 'call', side_effect=fake_call), patch.object(ssh.subprocess, 'Popen') as popen:
            with self.assertRaises(ValueError):
                ssh.serve(1)
            popen.assert_not_called()
        self.assertEqual(calls[-1], ('/api/auth/logout', {}, 'temporary'))

    def test_ssh_capacity_is_bounded_and_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            with contextlib.ExitStack() as stack:
                for _ in range(8):
                    stack.enter_context(ssh.transfer_slot(Path(tmp)))
                with self.assertRaises(ValueError):
                    with ssh.transfer_slot(Path(tmp)):
                        pass
            with ssh.transfer_slot(Path(tmp)):
                pass

    def test_http_redirect_does_not_forward_secret(self):
        received = []
        class Redirect(BaseHTTPRequestHandler):
            def do_GET(self):
                received.append(self.path)
                self.send_response(302)
                self.send_header('Location', '/unexpected')
                self.end_headers()
            def log_message(self, *args):
                pass
        server = HTTPServer(('127.0.0.1', 0), Redirect)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(os.environ, {'GITCLUB_URL': f'http://127.0.0.1:{server.server_port}', 'GITCLUB_SSH_SECRET': 'test-secret'}):
                with self.assertRaises(ssh.urllib.error.HTTPError) as error:
                    ssh.call('/api/ssh/authorized-keys')
                error.exception.close()
            self.assertEqual(received, ['/api/ssh/authorized-keys'])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main()

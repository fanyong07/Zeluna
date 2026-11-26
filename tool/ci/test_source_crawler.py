"""Offline ownership regressions; never run crawler discovery or live HTTP."""

from __future__ import annotations

import importlib.util
import io
import sys
import unittest
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch


class SourceCrawlerHttpTests(unittest.TestCase):
    def load_backend(self, httpx: bool):
        fake_http = SimpleNamespace(Client=MagicMock(), Timeout=Mock())
        name = "_source_crawler_test_backend"
        source = Path(__file__).resolve().parents[2] / "tools/source_crawler.py"
        spec = importlib.util.spec_from_file_location(name, source)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(
            sys.modules, {name: module, "httpx": fake_http if httpx else None}
        ):
            spec.loader.exec_module(module)
        self.assertEqual(module._HTTPX, httpx)
        return module, fake_http

    def httpx_fixture(self):
        module, backend = self.load_backend(True)
        client = backend.Client.return_value
        client.__enter__.return_value = client
        client.__exit__.side_effect = lambda *args: client.close() and False
        response = Mock(status_code=200, text="fixture")
        client.get.return_value = response
        return module, backend, client, response

    def test_httpx_success_closes_resources_and_preserves_request(self):
        module, backend, client, response = self.httpx_fixture()
        self.assertEqual(
            module._http_get("https://fixture.invalid/data", 7, {"X-Fixture": "yes"}),
            "fixture",
        )
        backend.Timeout.assert_called_once_with(7)
        backend.Client.assert_called_once_with(
            timeout=backend.Timeout.return_value, follow_redirects=True
        )
        client.get.assert_called_once()
        self.assertEqual(client.get.call_args.args, ("https://fixture.invalid/data",))
        headers = client.get.call_args.kwargs["headers"]
        self.assertEqual(headers["X-Fixture"], "yes")
        self.assertEqual(headers["Accept"], "application/json, text/plain, */*")
        self.assertIn("Chrome/124.0", headers["User-Agent"])
        response.close.assert_called_once_with()
        client.close.assert_called_once_with()

    def test_httpx_status_boundaries_close_on_accept_and_reject(self):
        for status in [199, 200, 204, 301, 404, 499, 500, 503]:
            with self.subTest(status=status):
                module, _, client, response = self.httpx_fixture()
                response.status_code = status
                expected = "fixture" if 200 <= status < 500 else None
                self.assertEqual(module._http_get("https://fixture.invalid"), expected)
                response.close.assert_called_once_with()
                client.close.assert_called_once_with()

    def test_httpx_get_exception_closes_client(self):
        module, _, client, response = self.httpx_fixture()
        client.get.side_effect = RuntimeError("offline failure")
        self.assertIsNone(module._http_get("https://fixture.invalid"))
        client.close.assert_called_once_with()
        response.close.assert_not_called()

    def test_httpx_text_exception_closes_response_and_client(self):
        from unittest.mock import PropertyMock

        module, _, client, response = self.httpx_fixture()
        type(response).text = PropertyMock(side_effect=UnicodeError("offline decode"))
        self.assertIsNone(module._http_get("https://fixture.invalid"))
        response.close.assert_called_once_with()
        client.close.assert_called_once_with()

    def test_httpx_constructor_exception_returns_none(self):
        module, backend = self.load_backend(True)
        backend.Client.side_effect = RuntimeError("offline constructor")
        self.assertIsNone(module._http_get("https://fixture.invalid"))

    def urllib_fixture(self):
        module, _ = self.load_backend(False)
        response = MagicMock()
        response.__enter__.return_value = response
        response.__exit__.side_effect = lambda *args: response.close() and False
        response.read.return_value = b"fixture\xff"
        return module, response

    def test_urllib_success_closes_response_and_preserves_request(self):
        module, response = self.urllib_fixture()
        with (
            patch.object(
                module.urllib.request, "urlopen", return_value=response
            ) as urlopen,
            patch.object(module.ssl, "create_default_context") as context,
        ):
            self.assertEqual(
                module._http_get(
                    "https://fixture.invalid/data", 9, {"Accept": "text/plain"}
                ),
                "fixture\ufffd",
            )
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, "https://fixture.invalid/data")
        self.assertEqual(request.get_header("Accept"), "text/plain")
        self.assertIn("Chrome/124.0", request.get_header("User-agent"))
        self.assertEqual(
            urlopen.call_args.kwargs, {"timeout": 9, "context": context.return_value}
        )
        response.close.assert_called_once_with()

    def test_urllib_read_and_decode_errors_close_response(self):
        for phase in ["read", "decode"]:
            with self.subTest(phase=phase):
                module, response = self.urllib_fixture()
                if phase == "read":
                    response.read.side_effect = OSError("offline read")
                else:
                    response.read.return_value = Mock()
                    response.read.return_value.decode.side_effect = UnicodeError(
                        "offline decode"
                    )
                with patch.object(
                    module.urllib.request, "urlopen", return_value=response
                ):
                    self.assertIsNone(module._http_get("https://fixture.invalid"))
                response.close.assert_called_once_with()

    def test_urllib_rejected_http_status_closes_error_response(self):
        module, _ = self.urllib_fixture()
        for status in [301, 404, 500]:
            with self.subTest(status=status):
                body = io.BytesIO(b"offline rejected response")
                error = urllib.error.HTTPError(
                    "https://fixture.invalid", status, "rejected", {}, body
                )
                with patch.object(module.urllib.request, "urlopen", side_effect=error):
                    self.assertIsNone(module._http_get("https://fixture.invalid"))
                self.assertTrue(body.closed)

    def test_urllib_open_exception_returns_none(self):
        module, response = self.urllib_fixture()
        with patch.object(
            module.urllib.request,
            "urlopen",
            side_effect=urllib.error.URLError("offline connection"),
        ):
            self.assertIsNone(module._http_get("https://fixture.invalid"))
        response.close.assert_not_called()


if __name__ == "__main__":
    unittest.main()

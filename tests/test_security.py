import asyncio
import os
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

import httpx


_test_data_dir = tempfile.TemporaryDirectory()
os.environ["LLM_CHAT_DATA_DIR"] = _test_data_dir.name
os.environ["LLM_BASE_URL"] = "http://127.0.0.1:9876/v1"
os.environ["LLM_ALLOWED_BASE_URLS"] = "http://localhost:11434/v1"
os.environ["LLM_MODEL"] = "test-model"
os.environ["LLM_API_KEY"] = "test-secret"
os.environ.pop("APP_CORS_ORIGINS", None)

from src.config import ALLOWED_LLM_BASE_URLS, normalize_llm_base_url  # noqa: E402
from src.attachment_processor import _resolve_stored_path  # noqa: E402
from src.server import app, llm_client  # noqa: E402


class SecurityTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://testserver",
        )

    async def asyncTearDown(self):
        await self.client.aclose()

    async def test_health_and_config_do_not_expose_api_key(self):
        health = await self.client.get("/api/health")
        config = await self.client.get("/api/config")
        self.assertEqual(health.json(), {"ok": True})
        self.assertNotIn("apiKey", config.json())
        self.assertNotIn("test-secret", config.text)

    async def test_unlisted_llm_url_is_rejected_without_network_request(self):
        with patch.object(llm_client, "probe", new=AsyncMock()) as probe:
            response = await self.client.get(
                "/api/llm-status",
                params={"llm_base_url": "http://169.254.169.254/latest"},
            )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["ok"])
        self.assertIn("LLM_ALLOWED_BASE_URLS", response.json()["message"])
        probe.assert_not_awaited()

    async def test_invalid_conversation_id_is_rejected(self):
        response = await self.client.get("/api/conversations/not-a-valid-id")
        self.assertEqual(response.status_code, 400)

    async def test_cors_is_disabled_by_default(self):
        response = await self.client.get(
            "/api/health",
            headers={"Origin": "https://untrusted.example"},
        )
        self.assertNotIn("access-control-allow-origin", response.headers)

    async def test_concurrent_messages_are_not_lost(self):
        conversation = (await self.client.post("/api/conversations")).json()

        async def fake_send(*args, **kwargs):
            await asyncio.sleep(0.01)
            return "ok"

        with patch.object(llm_client, "send_chat", side_effect=fake_send):
            responses = await asyncio.gather(
                self.client.post(
                    f"/api/conversations/{conversation['id']}/messages",
                    data={"content": "first"},
                ),
                self.client.post(
                    f"/api/conversations/{conversation['id']}/messages",
                    data={"content": "second"},
                ),
            )

        self.assertEqual([response.status_code for response in responses], [200, 200])
        stored = (await self.client.get(f"/api/conversations/{conversation['id']}")).json()
        self.assertEqual(len(stored["messages"]), 4)
        self.assertEqual(
            sorted(message["content"] for message in stored["messages"] if message["role"] == "user"),
            ["first", "second"],
        )

    def test_url_normalization_and_allowlist(self):
        self.assertEqual(
            normalize_llm_base_url("HTTP://LOCALHOST:11434/v1/"),
            "http://localhost:11434/v1",
        )
        self.assertIn("http://localhost:11434/v1", ALLOWED_LLM_BASE_URLS)
        with self.assertRaises(ValueError):
            normalize_llm_base_url("file:///etc/passwd")

    def test_llm_client_does_not_follow_redirects_and_redacts_error_body(self):
        self.assertFalse(llm_client.client.follow_redirects)
        response = httpx.Response(400, text="provider echoed test-secret")
        self.assertEqual(llm_client._safe_response_text(response), "provider echoed ****")

    def test_attachment_metadata_cannot_escape_data_directory(self):
        with self.assertRaises(ValueError):
            _resolve_stored_path({"stored_path": "../outside.txt"})


if __name__ == "__main__":
    unittest.main()

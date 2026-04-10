"""Locust load test scenarios for mobin pastebin.

Scenarios:
    ReadHeavyUser  — 80% reads (get paste), 10% list, 10% stats
    MixedUser      — 40% create, 40% read, 10% list, 10% delete own

Usage (headless, 50 users, 5/s spawn, 60s):
    pixi run load-test

Usage (web UI on :8089):
    pixi run load-ui

Environment:
    Set MOBIN_HOST to override the backend base URL (default: http://localhost:8080).
"""

import os
import random
import string
import threading
from typing import Optional

from locust import HttpUser, between, events, task
from locust.runners import MasterRunner, WorkerRunner


BASE_URL = os.environ.get("MOBIN_HOST", "http://localhost:8080")

# Shared pool of paste IDs so read-heavy users can fetch real IDs
_paste_pool: list[str] = []
_pool_lock = threading.Lock()
_POOL_MAX = 500


def _pool_add(paste_id: str) -> None:
    with _pool_lock:
        _paste_pool.append(paste_id)
        if len(_paste_pool) > _POOL_MAX:
            _paste_pool.pop(0)


def _pool_random() -> Optional[str]:
    with _pool_lock:
        if not _paste_pool:
            return None
        return random.choice(_paste_pool)


def _pool_remove(paste_id: str) -> None:
    with _pool_lock:
        try:
            _paste_pool.remove(paste_id)
        except ValueError:
            pass


def _random_content(lines: int = 10) -> str:
    """Generate random code-like content."""
    lang = random.choice(["python", "mojo", "plain"])
    words = [
        "fn", "var", "let", "if", "for", "while", "return", "struct",
        "import", "def", "print", "True", "False", "None",
    ]
    result = []
    for _ in range(lines):
        line_words = [random.choice(words) for _ in range(random.randint(3, 8))]
        result.append(" ".join(line_words))
    return "\n".join(result)


def _random_title() -> str:
    chars = string.ascii_lowercase + "_"
    length = random.randint(4, 20)
    return "".join(random.choice(chars) for _ in range(length))


# ---------------------------------------------------------------------------
# Warm up: seed paste pool on test start
# ---------------------------------------------------------------------------

@events.test_start.add_listener
def _on_test_start(environment, **kwargs) -> None:
    """Pre-seed the paste pool with 20 entries so read users have something to fetch."""
    if isinstance(environment.runner, (MasterRunner, WorkerRunner)):
        return  # Skip seeding on distributed runners (only relevant for standalone)

    import httpx
    seed_count = 20
    try:
        with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
            for i in range(seed_count):
                r = client.post(
                    "/paste",
                    json={
                        "content": f"seed paste {i}\n" + _random_content(5),
                        "title": f"seed_{i}",
                        "language": random.choice(["python", "mojo", "plain"]),
                        "ttl": 1,
                    },
                )
                if r.status_code == 200:
                    _pool_add(r.json()["id"])
    except Exception as exc:
        print(f"[locust] seed warning: {exc}")


# ---------------------------------------------------------------------------
# ReadHeavyUser: simulates an audience consuming pastes
# ---------------------------------------------------------------------------

class ReadHeavyUser(HttpUser):
    """Primarily reads pastes; occasionally lists and checks stats.

    Models a typical pastebin consumer who arrives via a shared link.
    """

    weight = 70  # 70% of the user mix
    wait_time = between(0.5, 2.0)

    @task(8)
    def get_paste(self) -> None:
        paste_id = _pool_random()
        if paste_id is None:
            return
        self.client.get(
            f"/paste/{paste_id}",
            name="/paste/[id]",
        )

    @task(1)
    def list_pastes(self) -> None:
        offset = random.randint(0, 50)
        self.client.get(
            f"/pastes?limit=20&offset={offset}",
            name="/pastes",
        )

    @task(1)
    def get_stats(self) -> None:
        self.client.get("/stats")

    @task(1)
    def get_health(self) -> None:
        with self.client.get("/health", catch_response=True) as r:
            if r.status_code != 200:
                r.failure(f"Health check failed: {r.status_code}")


# ---------------------------------------------------------------------------
# MixedUser: creates, reads, and occasionally cleans up own pastes
# ---------------------------------------------------------------------------

class MixedUser(HttpUser):
    """Creates pastes and reads them; occasionally deletes own pastes.

    Models a developer using the service for sharing snippets.
    """

    weight = 30  # 30% of the user mix
    wait_time = between(1.0, 3.0)

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._my_pastes: list[str] = []

    @task(4)
    def create_paste(self) -> None:
        lang = random.choice(["python", "mojo", "plain", "bash", "javascript"])
        payload = {
            "content": _random_content(random.randint(5, 30)),
            "title": _random_title(),
            "language": lang,
            "ttl": 1,
        }
        with self.client.post("/paste", json=payload, catch_response=True) as r:
            if r.status_code == 200:
                paste_id = r.json().get("id", "")
                if paste_id:
                    _pool_add(paste_id)
                    self._my_pastes.append(paste_id)
            else:
                r.failure(f"Create failed: {r.status_code} {r.text[:100]}")

    @task(4)
    def get_paste(self) -> None:
        # Prefer own pastes, fall back to pool
        if self._my_pastes:
            paste_id = random.choice(self._my_pastes)
        else:
            paste_id = _pool_random()
        if paste_id is None:
            return
        self.client.get(f"/paste/{paste_id}", name="/paste/[id]")

    @task(1)
    def list_recent(self) -> None:
        self.client.get("/pastes?limit=10&offset=0", name="/pastes")

    @task(1)
    def delete_own_paste(self) -> None:
        if not self._my_pastes:
            return
        paste_id = self._my_pastes.pop(0)
        _pool_remove(paste_id)
        with self.client.delete(
            f"/paste/{paste_id}",
            name="/paste/[id] DELETE",
            catch_response=True,
        ) as r:
            # 404 is acceptable (paste may have already expired)
            if r.status_code not in (200, 404):
                r.failure(f"Delete failed: {r.status_code}")

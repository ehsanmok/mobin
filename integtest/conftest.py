"""pytest fixtures for mobin integration tests.

Starts the backend binary as a subprocess and waits for it to be ready
before running tests. Tears it down cleanly after all tests complete.

Usage:
    cd integtest
    pixi install
    pixi run test

Requirements:
    - ../backend/mobin-backend must be built: cd ../backend && pixi run build
    - Ports 8080 and 8081 must be free
"""

import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Generator

import httpx
import pytest


REPO_ROOT = Path(__file__).parent.parent
BACKEND_BIN = REPO_ROOT / "backend" / "mobin-backend"
BACKEND_DIR = REPO_ROOT / "backend"
# mobin's mojo build env lives at the repo root, not under backend/. The
# root pixi.toml is what pulls flare/json/morph/sqlite/tempo/uuid/envo/pprint
# and runs the FFI activation hook that drops libflare_tls.so /
# libflare_zlib.so into ``.pixi/envs/default/lib/``.
PIXI_LIB_DIR = REPO_ROOT / ".pixi" / "envs" / "default" / "lib"
HTTP_PORT = 18080   # Use high ports to avoid conflicts with dev server
WS_PORT = 18081
BASE_URL = f"http://localhost:{HTTP_PORT}"
WS_URL = f"ws://localhost:{WS_PORT}/feed"
STARTUP_TIMEOUT = 15.0
POLL_INTERVAL = 0.25


def _is_ready(url: str) -> bool:
    """Return True if the backend health endpoint responds 200."""
    try:
        r = httpx.get(url + "/health", timeout=2.0)
        return r.status_code == 200
    except Exception:
        return False


def _is_port_open(host: str, port: int) -> bool:
    """Return True if a TCP connection to host:port can be established."""
    try:
        with socket.create_connection((host, port), timeout=1.0):
            return True
    except Exception:
        return False


def _kill_by_name(name: str) -> None:
    """Kill all processes matching name pattern (best-effort)."""
    try:
        subprocess.run(["pkill", "-9", "-f", name], check=False)
    except Exception:
        pass


def _kill_port(port: int) -> None:
    """Kill any process listening on port (best-effort)."""
    try:
        result = subprocess.run(
            ["lsof", "-ti", f"tcp:{port}"],
            capture_output=True, text=True, check=False,
        )
        pids = result.stdout.strip().split()
        for pid in pids:
            if pid.strip():
                try:
                    os.kill(int(pid.strip()), signal.SIGKILL)
                except (ProcessLookupError, ValueError):
                    pass
        if pids:
            time.sleep(0.5)
    except Exception:
        pass


@pytest.fixture(scope="session")
def backend_url() -> Generator[str, None, None]:
    """Session-scoped fixture that starts mobin-backend and yields its URL.

    Always starts a fresh backend with a temporary database so tests are
    isolated from any previously running instance. Uses MOBIN_URL env var
    to override (for CI with an already-running backend).
    """
    # Allow CI to supply a running instance
    override_url = os.environ.get("MOBIN_URL", "")
    if override_url:
        yield override_url.rstrip("/")
        return

    if not BACKEND_BIN.exists():
        pytest.skip(
            f"Backend binary not found at {BACKEND_BIN}. "
            "Run `cd backend && pixi run build` first."
        )
        return

    # Kill any lingering mobin-backend processes (zombie threads from previous runs)
    _kill_by_name("mobin-backend")
    time.sleep(0.3)
    # Kill anything still using our test ports
    _kill_port(HTTP_PORT)
    _kill_port(WS_PORT)
    time.sleep(0.3)

    # Use a temp dir for the test database so each session is isolated
    with tempfile.TemporaryDirectory() as tmpdir:
        env = os.environ.copy()
        # DB_PATH: matches envo's uppercase field name convention for db_path
        env["DB_PATH"] = str(Path(tmpdir) / "test.db")
        # Override ports so tests use high ports (no conflict with dev server)
        env["PORT"] = str(HTTP_PORT)
        env["WS_PORT"] = str(WS_PORT)
        # The backend reaches into ``$CONDA_PREFIX/lib/libflare_tls.so``
        # to load the WebSocket SHA-1 + TCP read/write bridge (see
        # ``flare.net.socket._find_flare_lib`` in flare v0.7). When the
        # integtest runs inside its own pixi env, ``CONDA_PREFIX``
        # points at ``integtest/.pixi/envs/default`` — which does NOT
        # ship ``libflare_tls.so``. Forcing ``CONDA_PREFIX`` (and
        # ``LD_LIBRARY_PATH`` / ``DYLD_LIBRARY_PATH`` for good measure)
        # to the root mobin pixi env lets the binary find the flare
        # bridge plus the simdjson + openssl runtime deps it links
        # against. The root activation script
        # ``scripts/build_flare_ffi.sh`` is what drops the .so files
        # there in the first place.
        mobin_pixi_env = PIXI_LIB_DIR.parent  # .pixi/envs/default
        if PIXI_LIB_DIR.joinpath("libflare_tls.so").exists():
            env["CONDA_PREFIX"] = str(mobin_pixi_env)
            existing_ld = env.get("LD_LIBRARY_PATH", "")
            env["LD_LIBRARY_PATH"] = (
                str(PIXI_LIB_DIR)
                + (":" + existing_ld if existing_ld else "")
            )
            existing_dyld = env.get("DYLD_LIBRARY_PATH", "")
            env["DYLD_LIBRARY_PATH"] = (
                str(PIXI_LIB_DIR)
                + (":" + existing_dyld if existing_dyld else "")
            )

        log_path = Path(tmpdir) / "backend.log"
        log_file = open(log_path, "w")
        proc = subprocess.Popen(
            [str(BACKEND_BIN)],
            cwd=str(BACKEND_DIR),
            stdout=log_file,
            stderr=log_file,
            env=env,
            # start_new_session puts parent + forked WS child in their own
            # process group so we can kill both with os.killpg() on teardown.
            start_new_session=True,
        )

        deadline = time.monotonic() + STARTUP_TIMEOUT
        while not (_is_ready(BASE_URL) and _is_port_open("localhost", WS_PORT)):
            if time.monotonic() > deadline:
                proc.kill()
                proc.wait(timeout=3)
                log_file.flush()
                log_content = log_path.read_text(errors="replace") if log_path.exists() else ""
                pytest.fail(
                    f"Backend did not start within {STARTUP_TIMEOUT}s.\n"
                    f"Output:\n{log_content}"
                )
            if proc.poll() is not None:
                log_file.flush()
                log_content = log_path.read_text(errors="replace") if log_path.exists() else ""
                pytest.fail(
                    f"Backend exited prematurely (rc={proc.returncode}).\n"
                    f"Output:\n{log_content}"
                )
            time.sleep(POLL_INTERVAL)

        yield BASE_URL

        # Kill the entire process group (parent HTTP server + forked WS child).
        # proc.kill() only sends SIGKILL to the parent; start_new_session=True
        # above gave them a dedicated process group so we can reach all of them.
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
        log_file.close()
        print("\n=== Backend log ===")
        print(log_path.read_text(errors="replace"))
        print("=== End backend log ===")


@pytest.fixture
def client(backend_url: str) -> httpx.Client:
    """HTTP client pre-configured with the backend base URL."""
    with httpx.Client(base_url=backend_url, timeout=10.0) as c:
        yield c

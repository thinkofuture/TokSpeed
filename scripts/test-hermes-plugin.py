#!/usr/bin/env python3
"""End-to-end fixture: install, register hook, emit calls, and read via TokSpeed CLI."""

import argparse
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import ModuleType, SimpleNamespace


def simulated_hook(home):
    """Mirror Hermes's documented directory plugin and register(ctx) interface."""
    path = home / "plugins" / "tokspeed-metrics"
    assert "name: tokspeed-metrics\n" in (path / "plugin.yaml").read_text()
    constants = ModuleType("hermes_constants")
    constants.get_hermes_home = lambda: home
    sys.modules["hermes_constants"] = constants
    spec = importlib.util.spec_from_file_location("tokspeed_metrics", path / "__init__.py")
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    hooks = {}
    plugin.register(SimpleNamespace(register_hook=hooks.__setitem__))
    return lambda name, **event: hooks[name](**event)


def actual_hook(home, source):
    """Exercise local Hermes discovery, dispatcher, intake and canonical usage."""
    from unittest.mock import patch

    sys.path.insert(0, str(source))
    os.environ["HERMES_HOME"] = str(home)
    os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
    from agent.api_request_hooks import ApiRequestHooksMixin
    from agent.turn_response_intake import _fire_post_api_request_hook
    from hermes_cli import plugins

    with patch.object(plugins, "get_bundled_plugins_dir", return_value=home / "no-bundled-plugins"):
        plugins.discover_plugins()
    assert not plugins.has_hook("post_api_request"), "On-disk files alone must not opt in"
    (home / "config.yaml").write_text("plugins:\n  enabled: [tokspeed-metrics]\n")
    with patch.object(plugins, "get_bundled_plugins_dir", return_value=home / "no-bundled-plugins"):
        plugins.discover_plugins(force=True)
    assert plugins.has_hook("post_api_request")

    class Agent(ApiRequestHooksMixin):
        api_mode = "chat_completions"
        platform = "cli"
        base_url = "https://private.invalid"

    def emit(name, **event):
        if name != "post_api_request":
            from hermes_cli.lifecycle import invoke_hook
            invoke_hook(name, **event)
            return
        agent = Agent()
        agent.model, agent.provider, agent.session_id = event["model"], event["provider"], event["session_id"]
        agent._last_api_first_chunk_at = event["first_chunk_at"]
        usage = event["usage"]
        response = SimpleNamespace(model=agent.model, usage=None if usage is None else SimpleNamespace(
            prompt_tokens=usage["prompt_tokens"], completion_tokens=usage["output_tokens"],
            total_tokens=usage["prompt_tokens"] + usage["output_tokens"]))
        if usage is not None:
            assert agent._usage_summary_for_api_request_hook(response)["output_tokens"] == usage["output_tokens"]
        _fire_post_api_request_hook(
            agent, response, SimpleNamespace(content="PRIVATE_REPLY", tool_calls=[]), "stop",
            api_messages=[{"content": "PRIVATE_PROMPT"}], api_call_count=1,
            api_duration=event["ended_at"] - event["started_at"], api_start_time=event["started_at"],
            api_request_id=event["api_request_id"], effective_task_id="PRIVATE_TASK", turn_id="fixture-turn",
        )

    return emit


def run(binary, source):
    with TemporaryDirectory(prefix="tokspeed-hermes-") as tmp:
        home = Path(tmp)
        env = dict(os.environ, HERMES_HOME=str(home))

        def cli(*args, check=True):
            return subprocess.run([binary, *args], env=env, text=True, capture_output=True, check=check)

        def once(count, basis, speed):
            result = cli("--once", "--source", "hermes").stdout
            assert f"samples:   {count}\n" in result, result
            assert f"basis:     {basis}\n" in result, result
            assert f"speed:     {speed} tok/s\n" in result, result
            return result

        config = home / "config.yaml"
        config.write_text("plugins:\n  enabled: []\n")
        original = config.read_bytes()
        cli("--install-hermes-plugin")
        cli("--install-hermes-plugin")
        assert config.read_bytes() == original, "TokSpeed must not edit config"

        manifest = home / "plugins" / "tokspeed-metrics" / "plugin.yaml"
        manifest_data = manifest.read_bytes()
        plugin_py = home / "plugins" / "tokspeed-metrics" / "__init__.py"
        plugin_py_data = plugin_py.read_bytes()

        # Foreign plugin conflict must fail even with --force.
        manifest.write_text("name: a-user-owned-plugin\n")
        conflict = cli("--install-hermes-plugin", check=False)
        assert conflict.returncode != 0 and manifest.read_text() == "name: a-user-owned-plugin\n"
        forced_conflict = cli("--install-hermes-plugin", "--force", check=False)
        assert forced_conflict.returncode != 0 and manifest.read_text() == "name: a-user-owned-plugin\n"

        # Older TokSpeed-owned plugin fails without --force, upgrades cleanly with --force.
        manifest.write_bytes(manifest_data)
        plugin_py.write_text("# older version\n")
        outdated_no_force = cli("--install-hermes-plugin", check=False)
        assert outdated_no_force.returncode != 0
        cli("--install-hermes-plugin", "--force")
        assert plugin_py.read_bytes() == plugin_py_data

        emit = actual_hook(home, source) if source else simulated_hook(home)
        journal = home / "plugin-data" / "tokspeed-metrics" / "calls.jsonl"
        logs = home / "logs"
        logs.mkdir(exist_ok=True)
        start = 1794000000.0

        def line(end, index, output, seconds):
            stamp = datetime.fromtimestamp(end).strftime("%Y-%m-%d %H:%M:%S,%f")[:-3]
            return (f"{stamp} INFO [private-session] agent.conversation_loop: API call #{index}: "
                    f"model=test-model provider=local in=20 out={output} total={20+output} latency={seconds:.1f}s\n")

        (logs / "agent.log").write_text(line(start - 1, 10, 100, 4) + line(start + 4.03, 11, 120, 4))
        once(2, "E2E fallback (agent log)", "30")

        def call(index, offset, first, output=120, session="private-session"):
            emit("post_api_request", task_id="PRIVATE_TASK", turn_id="private-turn", api_request_id=f"private-turn:api:{index}",
                 session_id=session, model="test-model", provider="local", api_mode="chat_completions",
                 started_at=start + offset, ended_at=start + offset + 4, first_chunk_at=first,
                 usage=None if output is None else {"prompt_tokens": 20, "output_tokens": output},
                 response={"assistant_message": {"content": "PRIVATE_REPLY"}},
                 assistant_message={"tool_calls": [{"args": "PRIVATE_ARGS"}]}, base_url="https://private.invalid")

        call(1, 0, start + 2.5)
        call(1, 0, start + 2.5)
        result = once(2, "Stream estimate", "80")
        assert "TTFC:      2.50s" in result and "stream:    1.50s" in result, result
        call(2, 6, None)
        once(3, "E2E fallback (hook)", "30")
        call(3, 12, (start + 14) * 1_000)  # milliseconds must not become stream timing
        once(4, "E2E fallback (hook)", "30")
        call(4, 18, start + 21.95)  # too short
        call(5, 24, start + 27.75, output=1000)  # too fast
        once(6, "E2E fallback (hook)", "250")
        call(6, 30, start + 29)  # stale timestamp, before this call
        call(7, 36, start + 38, output=None)
        call(8, 42, start + 44, output=0)
        once(7, "E2E fallback (hook)", "30")
        recorded = journal.read_text()
        for excluded in ("PRIVATE_", "private-turn", "private-session", "private.invalid", "assistant_message"):
            assert excluded not in recorded
        rows = [json.loads(line) for line in recorded.splitlines()]
        assert len(rows) == 7 and set(rows[0]) == {
            "v", "session", "request", "model", "provider", "started_at", "ended_at", "first_chunk_at", "input", "output"
        }
        assert journal.stat().st_mode & 0o777 == 0o600
        active = dict(session_id="activity PRIVATE_SESSION", api_request_id="PRIVATE_REQUEST",
                      started_at=datetime.now().timestamp(), user_message="PRIVATE_PROMPT")
        emit("pre_api_request", **active)
        assert "active:    true\n" in cli("--once", "--source", "hermes").stdout
        emit("api_request_error", **active)
        assert "active:    false\n" in cli("--once", "--source", "hermes").stdout
        activity_log = journal.with_name("activity.jsonl")
        assert "PRIVATE_" not in activity_log.read_text()
        assert activity_log.stat().st_mode & 0o777 == 0o600
        remaining = 2 * 1024 * 1024 - journal.stat().st_size
        with journal.open("a") as file:
            file.write("x" * (remaining - 1) + "\n")
        call(9, 48, start + 50)
        assert journal.with_suffix(".jsonl.1").exists()
        assert journal.stat().st_size < 4096
        once(8, "Stream estimate", "60")
        call(9, 54, start + 56, session="second-session")  # ID reuse in another session
        once(1, "Stream estimate", "60")
        call(10, 60, start + 65, session="second-session")  # chunk after end
        once(2, "E2E fallback (hook)", "30")
        call(11, start * 999, None, session="second-session")  # invalid epoch units
        once(2, "E2E fallback (hook)", "30")

        # Uninstall cleans up TokSpeed plugin without touching user config.
        before_remove = config.read_bytes()  # Actual Hermes fixture opted in explicitly.
        cli("--uninstall-hermes-plugin")
        assert not (home / "plugins" / "tokspeed-metrics").exists()
        assert config.read_bytes() == before_remove
        print("Hermes plugin E2E passed (" + ("real Hermes loader and intake" if source else "simulated Hermes dispatcher") + ")")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("build/TokSpeed.app/Contents/MacOS/TokSpeed"))
    parser.add_argument("--hermes-source", type=Path, help="use actual Hermes modules (run with its Python environment)")
    args = parser.parse_args()
    run(args.binary.resolve(), args.hermes_source)

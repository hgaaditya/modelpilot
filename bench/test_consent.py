"""Self-check for the code-execution consent gate in run.py.

    python bench/test_consent.py

The python grader runs code a model wrote, as you, on this machine. That path is worth a test
that fails loudly if it ever stops asking - a regression here is silent by nature, because the
symptom is code running that should not have.
"""

import builtins
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("bench_run", Path(__file__).with_name("run.py"))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)

saved = run.CONSENT.read_bytes() if run.CONSENT.exists() else None
try:
    run.CONSENT.unlink(missing_ok=True)
    sys.stdin.isatty = lambda: True

    builtins.input = lambda p="": "nope"
    assert run.allow_code_execution(False) is False, "a declined answer must not grant"
    assert not run.CONSENT.exists(), "a decline must not be recorded as consent"

    # Whitespace and case shouldn't matter; anything that isn't yes should.
    builtins.input = lambda p="": "  YES  "
    assert run.allow_code_execution(False) is True, "yes must grant"
    assert run.CONSENT.exists(), "yes must be remembered"

    builtins.input = lambda p="": (_ for _ in ()).throw(AssertionError("must not ask again"))
    assert run.allow_code_execution(False) is True, "recorded consent must be honoured silently"

    # The grader is the last line of defence: even reached directly, it must not execute.
    run.ALLOW_EXEC = False
    ok, note = run.grade_python({"tests": "", "timeout": 5},
                                "```python\nopen('consent-gate-breach','w')\n```")
    assert ok is False and "not permitted" in note, "grader must fail closed, got %r" % note
    assert not Path("consent-gate-breach").exists(), "grader executed code with ALLOW_EXEC off"
finally:
    run.CONSENT.unlink(missing_ok=True)
    if saved is not None:
        run.CONSENT.write_bytes(saved)

print("OK")

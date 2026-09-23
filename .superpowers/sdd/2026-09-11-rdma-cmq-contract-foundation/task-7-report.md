# Task 7 report

## Scope

Added the diff-aware SystemVerilog style checker, its temporary-Git unit tests,
and the `sim/sv_style` Make gate. Task 7A approval preflight was intentionally
left out.

## Verification

* RED: `python3 -m unittest tests.unit.test_check_changed_sv_style -v` was run
  before creating the checker and failed with the expected missing-file errors.
* GREEN: the same command after implementation passed all 7 tests.
* `python3 -m py_compile tools/check_changed_sv_style.py tests/unit/test_check_changed_sv_style.py`
  completed successfully.
* `make -C sim -n sv_style STYLE_BASE=cc07586` printed the two expected gate
  commands (`check_changed_sv_style.py` followed by `git diff --check`).
* `git diff --check` completed successfully for the implementation changes.
* `bash -n sim/Makefile` is not applicable because Makefile syntax is not shell
  syntax; Make's dry-run parser check above was used instead.
* Generated `tools/__pycache__` and `tests/unit/__pycache__` directories were
  removed after verification.

## Notes

The checker emits hard diagnostics for changed-line style violations and
`soft-limit` diagnostics for newly added lines over 100 columns. Repository-wide
execution may still report pre-existing dirty SystemVerilog outside this task;
those files are not edited by the gate implementation.

## Review fix round 1

The first review identified that line-by-line comment stripping reset block-comment
state. The checker now sanitizes each complete source with one shared state object,
so changed-line counting, method discovery, and case discovery all ignore
multi-line comments and strings consistently. The compliant-method fixture now
adds constructor/accessor/task/probe/helper methods only in the changed worktree,
and a dedicated CLI test covers a missing `--base` argument. A regression fixture
places fake function, case, and semicolon text inside a multi-line block comment.

Review-round verification:

* `python3 -m unittest tests.unit.test_check_changed_sv_style -v`: 9 tests passed.
* `python3 -m py_compile tools/check_changed_sv_style.py tests/unit/test_check_changed_sv_style.py`:
  passed.
* `make -C sim -n sv_style STYLE_BASE=cc07586`: emitted the checker and
  `git diff --check` commands successfully.
* `git diff --check`: passed.
* `tests/unit/__pycache__` and `tools/__pycache__` were removed after the run.

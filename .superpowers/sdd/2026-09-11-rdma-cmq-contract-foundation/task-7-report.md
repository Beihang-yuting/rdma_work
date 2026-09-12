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

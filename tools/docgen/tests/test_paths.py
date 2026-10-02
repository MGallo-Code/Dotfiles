import sys

import pytest

from docgen.paths import (
    DEFAULT_OUTPUT_DIR,
    PathError,
    resolve_base_dir,
    resolve_input_path,
    resolve_output_path,
)


# Cross-platform: pick a file that exists AND lives outside our allowlist.
OUTSIDE_ALLOWLIST_FILE = (
    r"C:\Windows\System32\drivers\etc\hosts" if sys.platform == "win32" else "/etc/hosts"
)
OUTSIDE_ALLOWLIST_NONEXISTENT = (
    r"C:\nope-not-a-real-file-xyz.bin" if sys.platform == "win32" else "/tmp-nope/definitely-not-a-real-file-xyz.bin"
)
# An existing directory that lives outside the allowlist roots.
OUTSIDE_ALLOWLIST_DIR = (
    r"C:\Windows\System32" if sys.platform == "win32" else "/etc"
)


def test_relative_resolves_against_output_dir():
    p = resolve_output_path("foo.pdf")
    assert p == (DEFAULT_OUTPUT_DIR / "foo.pdf").resolve()


def test_absolute_in_allowed_root_accepted(tmp_path):
    # tmp_path is under /tmp (or /var/folders symlinked to /private/var); allowed root /tmp
    # may not match macOS's /var/folders. Use the output dir (under $HOME) to be portable.
    target = DEFAULT_OUTPUT_DIR / "abs-test.pdf"
    p = resolve_output_path(str(target))
    assert p == target.resolve()


def test_absolute_outside_allowed_root_rejected():
    target = r"C:\etc\passwd-out.pdf" if sys.platform == "win32" else "/etc/passwd-out.pdf"
    with pytest.raises(PathError):
        resolve_output_path(target)


def test_overwrite_false_blocks_existing(tmp_path):
    existing = DEFAULT_OUTPUT_DIR / "overwrite-guard.pdf"
    existing.write_bytes(b"existing")
    try:
        with pytest.raises(PathError):
            resolve_output_path(str(existing), overwrite=False)
    finally:
        existing.unlink(missing_ok=True)


def test_overwrite_true_allows_existing():
    existing = DEFAULT_OUTPUT_DIR / "overwrite-ok.pdf"
    existing.write_bytes(b"existing")
    try:
        p = resolve_output_path(str(existing), overwrite=True)
        assert p == existing.resolve()
    finally:
        existing.unlink(missing_ok=True)


def test_resolve_input_missing_raises():
    with pytest.raises(PathError):
        resolve_input_path(OUTSIDE_ALLOWLIST_NONEXISTENT)


def test_resolve_input_outside_allowed_root_raises():
    # File exists but lives outside our allowlist roots.
    with pytest.raises(PathError):
        resolve_input_path(OUTSIDE_ALLOWLIST_FILE)


# --- base_dir sandbox (regression: an out-of-root base_dir was an arbitrary-write
#     primitive because _render_pdf writes a temp .html into it and serves via file://) ---

def test_resolve_base_dir_outside_root_raises():
    # An existing directory outside the allowlist must be rejected.
    with pytest.raises(PathError):
        resolve_base_dir(OUTSIDE_ALLOWLIST_DIR)


def test_resolve_base_dir_nonexistent_raises():
    with pytest.raises(PathError):
        resolve_base_dir(OUTSIDE_ALLOWLIST_NONEXISTENT)


def test_resolve_base_dir_valid_returns():
    p = resolve_base_dir(str(DEFAULT_OUTPUT_DIR))
    assert p == DEFAULT_OUTPUT_DIR.resolve()


def test_build_html_rejects_out_of_root_base_dir():
    """The fix at the bug site: _build_html must refuse an out-of-root base_dir
    BEFORE _render_pdf would write a temp file into it. No browser needed."""
    from docgen.models import PdfOptions
    from docgen.pdf import _build_html

    with pytest.raises(PathError):
        _build_html("<p>hi</p>", "", PdfOptions(base_dir=OUTSIDE_ALLOWLIST_DIR))

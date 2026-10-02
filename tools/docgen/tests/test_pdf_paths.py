"""Path handling in PDF rendering that must hold on every platform (no browser needed).

Rendering by path broke on Windows: the base folder went out as a file:// URL and was sliced back
into "/C:/Users/...", and the temp page was loaded as "file://C:\\Users\\...". The folder now stays
a Path end to end and every page URL is built from a path, so these run on Linux and macOS too.
"""
from pathlib import Path, PurePosixPath, PureWindowsPath

from docgen.models import PdfOptions
from docgen.pdf import _build_html, _looks_like_path, _page_uri


def test_page_uri_from_a_windows_path():
    uri = _page_uri(PureWindowsPath(r"C:\Users\moses\AppData\Local\Temp\tmp1234.html"))
    assert uri == "file:///C:/Users/moses/AppData/Local/Temp/tmp1234.html"


def test_page_uri_from_a_posix_path():
    assert _page_uri(PurePosixPath("/Users/mike/out/tmp1234.html")) == "file:///Users/mike/out/tmp1234.html"


def test_render_by_path_keeps_the_base_folder_a_path(tmp_path):
    src = tmp_path / "doc.html"
    src.write_text("<h1>Doc</h1>", encoding="utf-8")
    _, base_dir, from_path = _build_html(str(src), "", PdfOptions())
    assert from_path is True
    assert isinstance(base_dir, Path) and base_dir == src.parent.resolve()


def test_inline_html_is_never_taken_for_a_path(tmp_path):
    for value in ("<h1>Hi</h1>", "line one\nline two", r"C:\Users\x\<b>.html", "x" * 2000):
        assert _looks_like_path(value) is False
    existing = tmp_path / "page.html"
    existing.write_text("hi", encoding="utf-8")
    assert _looks_like_path(str(existing)) is True

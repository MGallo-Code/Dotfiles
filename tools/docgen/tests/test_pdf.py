"""PDF tests — slow, opt in with --slow."""

from __future__ import annotations

from pathlib import Path

import pytest
import pytest_asyncio

from docgen.pdf import register_pdf_tools
from docgen.server import mcp, shutdown_browser


pytestmark = [pytest.mark.slow, pytest.mark.asyncio]


@pytest_asyncio.fixture(autouse=True)
async def _close_browser_each_test():
    """Close the cached browser on THIS test's event loop after each test.

    pytest-asyncio 1.x runs each test in its own function-scoped loop, but the
    server caches the browser in a module global. If it isn't closed here, the
    singleton outlives the loop it was launched on, so the next test - and pytest
    itself at exit - hangs awaiting a dead transport. (The old session-scoped
    `event_loop` override that used to keep one loop alive is ignored in
    pytest-asyncio 1.x, which is why this regressed.)
    """
    yield
    await shutdown_browser()


@pytest_asyncio.fixture(scope="session", autouse=True)
async def setup_and_teardown():
    register_pdf_tools(mcp)
    yield
    await shutdown_browser()


def _tool(name: str):
    return mcp._tool_manager.get_tool(name).fn


async def test_pdf_from_html_inline(tmp_path: Path):
    out = tmp_path / "hello.pdf"
    res = await _tool("pdf_from_html")(
        html_or_path="<h1>Hello</h1><p>World</p>",
        output_path=str(out),
        css="h1 { color: blue }",
    )
    assert res["ok"], res
    data = Path(res["path"]).read_bytes()
    assert data.startswith(b"%PDF-"), "missing PDF magic bytes"
    assert res["bytes_written"] > 500


async def test_pdf_from_html_with_options(tmp_path: Path):
    out = tmp_path / "landscape.pdf"
    res = await _tool("pdf_from_html")(
        html_or_path="<h1>Landscape</h1>",
        output_path=str(out),
        options={"landscape": True, "page_size": "A4"},
    )
    assert res["ok"], res


async def test_pdf_from_markdown(tmp_path: Path):
    out = tmp_path / "md.pdf"
    res = await _tool("pdf_from_html")(
        html_or_path="# Heading\n\nBody with **bold**.",
        output_path=str(out),
        options={"markdown": True},
    )
    assert res["ok"], res
    assert Path(res["path"]).read_bytes().startswith(b"%PDF-")


async def test_pdf_merge_concatenates(tmp_path: Path):
    a = tmp_path / "a.pdf"
    b = tmp_path / "b.pdf"
    out = tmp_path / "merged.pdf"

    res_a = await _tool("pdf_from_html")(html_or_path="<h1>A</h1>", output_path=str(a))
    res_b = await _tool("pdf_from_html")(html_or_path="<h1>B</h1>", output_path=str(b))
    assert res_a["ok"] and res_b["ok"]

    res = await _tool("pdf_merge")(input_paths=[str(a), str(b)], output_path=str(out))
    assert res["ok"], res

    from pypdf import PdfReader

    reader = PdfReader(str(out))
    assert len(reader.pages) >= 2


async def test_pdf_returns_page_count(tmp_path: Path):
    out = tmp_path / "counted.pdf"
    res = await _tool("pdf_from_html")(html_or_path="<h1>One page</h1>", output_path=str(out))
    assert res["ok"], res
    assert res.get("page_count") == 1


async def test_pdf_inline_hint_and_save_source(tmp_path: Path):
    big = "<h1>Big</h1>" + "<p>filler. </p>" * 300  # > 2000 chars, inline
    # default: a hint nudges the file-based iteration workflow
    res = await _tool("pdf_from_html")(html_or_path=big, output_path=str(tmp_path / "h.pdf"))
    assert res["ok"] and "hint" in res

    # save_source persists the source and suppresses the hint
    res2 = await _tool("pdf_from_html")(
        html_or_path=big, output_path=str(tmp_path / "s.pdf"), options={"save_source": True}
    )
    assert res2["ok"] and "hint" not in res2
    assert Path(res2["source_path"]).exists()

    # rendering by path emits neither hint nor source_path
    res3 = await _tool("pdf_from_html")(html_or_path=res2["source_path"], output_path=str(tmp_path / "p.pdf"))
    assert res3["ok"] and "hint" not in res3 and "source_path" not in res3


async def test_pdf_preview_writes_png(tmp_path: Path):
    out = tmp_path / "prev.pdf"
    res = await _tool("pdf_from_html")(
        html_or_path="<h1>Preview me</h1>", output_path=str(out), options={"preview": True}
    )
    assert res["ok"], res
    preview = Path(res["preview_path"])
    assert preview.exists() and preview.suffix == ".png"
    assert preview.read_bytes().startswith(b"\x89PNG")


async def test_pdf_overwrite_guard(tmp_path: Path):
    out = tmp_path / "guard.pdf"
    out.write_bytes(b"%PDF-1.4 existing")
    res = await _tool("pdf_from_html")(
        html_or_path="<p>x</p>",
        output_path=str(out),
        options={"overwrite": False},
    )
    assert res["ok"] is False
    assert "overwrite" in res["error"].lower()

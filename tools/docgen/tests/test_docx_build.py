"""Tests for docx_create_from_spec — exercise each block type and assert via XML."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from docgen.docx_build import register_docx_build_tools
from docgen.server import mcp


@pytest.fixture(scope="module", autouse=True)
def register_tools():
    register_docx_build_tools(mcp)


def call_tool(name: str, **kwargs):
    tool = asyncio.get_event_loop().run_until_complete if False else None
    # FastMCP keeps tools internally; reach in via the registered handler.
    handler = _registered(name)
    return asyncio.run(handler(**kwargs))


def _registered(name: str):
    # Find the underlying function FastMCP wrapped during @server.tool decoration.
    for tool in mcp._tool_manager.list_tools():
        if tool.name == name:
            return mcp._tool_manager.get_tool(name).fn
    raise KeyError(name)


def test_heading_and_paragraph(tmp_path: Path, docx_xml):
    out = tmp_path / "headings.docx"
    spec = {
        "blocks": [
            {"type": "heading", "level": 1, "text": "Title"},
            {"type": "paragraph", "text": "Hello world.", "style": {"bold": True}},
        ],
    }
    res = call_tool("docx_create_from_spec", spec=spec, output_path=str(out))
    assert res["ok"], res
    assert Path(res["path"]).exists()
    xml = docx_xml(Path(res["path"]))
    assert "Title" in xml
    assert "Hello world." in xml


def test_list_and_table(tmp_path: Path, docx_xml):
    out = tmp_path / "lists_tables.docx"
    spec = {
        "blocks": [
            {"type": "list", "items": ["one", "two", "three"], "ordered": True},
            {"type": "table", "rows": [["a", "b"], ["c", "d"]], "header": True},
        ],
    }
    res = call_tool("docx_create_from_spec", spec=spec, output_path=str(out))
    assert res["ok"], res
    xml = docx_xml(Path(res["path"]))
    for s in ("one", "two", "three", "a", "b", "c", "d"):
        assert s in xml


def test_page_break(tmp_path: Path, docx_xml):
    out = tmp_path / "page_break.docx"
    spec = {
        "blocks": [
            {"type": "paragraph", "text": "Before."},
            {"type": "page_break"},
            {"type": "paragraph", "text": "After."},
        ],
    }
    res = call_tool("docx_create_from_spec", spec=spec, output_path=str(out))
    assert res["ok"], res
    xml = docx_xml(Path(res["path"]))
    assert 'w:type="page"' in xml


def test_table_grid_fallback_when_reference_lacks_style(tmp_path: Path, docx_xml):
    """A reference doc without the 'Table Grid' style must not crash the render.

    Regression: docx_create_from_spec hardcoded `table.style = "Table Grid"`, which
    KeyErrors on third-party/exported reference docs that lack that built-in style.
    The fallback draws manual borders so the table still renders gridded.
    """
    from docx import Document

    ref = tmp_path / "ref_no_grid.docx"
    d = Document()
    el = d.styles["Table Grid"]._element  # strip the style to simulate a foreign doc
    el.getparent().remove(el)
    d.save(ref)

    out = tmp_path / "grid_fallback.docx"
    spec = {"blocks": [{"type": "table", "rows": [["a", "b"], ["c", "d"]], "header": True}]}
    res = call_tool("docx_create_from_spec", spec=spec, output_path=str(out), reference_doc=str(ref))
    assert res["ok"], res
    xml = docx_xml(Path(res["path"]))
    assert "tblBorders" in xml, "fallback borders not applied"
    for s in ("a", "b", "c", "d"):
        assert s in xml


def test_bad_block_returns_error(tmp_path: Path):
    out = tmp_path / "bad.docx"
    spec = {"blocks": [{"type": "nonsense", "text": "x"}]}
    res = call_tool("docx_create_from_spec", spec=spec, output_path=str(out))
    assert res["ok"] is False
    assert "Invalid spec" in res["error"]


def test_image_block(tmp_path: Path):
    # Use python-docx's own bundled test image via a generated minimal PNG.
    png_bytes = bytes.fromhex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
        "890000000d49444154789c63f8cf00000003010100"  # may be slightly invalid; rely on Pillow round-trip
    )
    # Generate a valid 1x1 PNG via Pillow instead.
    from PIL import Image
    img_path = tmp_path / "tiny.png"
    Image.new("RGB", (10, 10), "red").save(img_path)

    out = tmp_path / "image.docx"
    spec = {
        "blocks": [{"type": "image", "path": str(img_path), "width_in": 1.0}],
    }
    res = call_tool("docx_create_from_spec", spec=spec, output_path=str(out))
    assert res["ok"], res
    # python-docx writes the image into the docx zip as media/image*.png
    import zipfile

    with zipfile.ZipFile(res["path"]) as zf:
        media = [n for n in zf.namelist() if n.startswith("word/media/")]
    assert media, "no media files embedded"

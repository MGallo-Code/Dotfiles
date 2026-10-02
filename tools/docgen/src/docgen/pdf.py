"""PDF generation tools backed by Playwright (HTML/CSS) and pypdf (merge)."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated, Any

from mcp.server.fastmcp import FastMCP
from pydantic import Field

from docgen.models import PdfOptions
from docgen.paths import PathError, resolve_base_dir, resolve_input_path, resolve_output_path
from docgen.utils import err, ok

_BASIC_MD_SHELL = """<!doctype html>
<html><head><meta charset="utf-8"><style>{css}</style></head>
<body>{body}</body></html>"""


def _looks_like_path(value: str) -> bool:
    """Heuristic: treat short single-line strings without `<` as candidate paths."""
    if "\n" in value or "<" in value:
        return False
    if len(value) > 1024:
        return False
    try:
        return Path(value).expanduser().exists()
    except OSError:
        return False


def _build_html(html_or_path: str, css: str, options: PdfOptions) -> tuple[str, str | None, bool]:
    """Return (html_string, base_url, from_path) ready for Playwright.

    `from_path` is True when html_or_path was an existing file (vs inline content);
    callers use it to decide whether to nudge the file-based iteration workflow.
    """
    from_path = _looks_like_path(html_or_path)
    if from_path:
        path = resolve_input_path(html_or_path)
        raw = path.read_text(encoding="utf-8")
        base = options.base_dir or str(path.parent)
    else:
        raw = html_or_path
        base = options.base_dir

    if options.markdown:
        import markdown as md

        body = md.markdown(raw, extensions=["extra", "sane_lists", "tables"])
        raw = _BASIC_MD_SHELL.format(css=css, body=body)
        css = ""  # baked into shell already

    if css and "<style" not in raw:
        raw = raw.replace("</head>", f"<style>{css}</style></head>", 1) if "</head>" in raw \
            else f"<style>{css}</style>" + raw

    base_url = None
    if base:
        # Validate before use: _render_pdf writes a temp .html into this dir and serves
        # it via file://, so an out-of-root base_dir would escape the sandbox.
        base_path = resolve_base_dir(base)
        base_url = base_path.as_uri() + "/"
    return raw, base_url, from_path


def _playwright_pdf_kwargs(options: PdfOptions) -> dict[str, Any]:
    kwargs: dict[str, Any] = {
        "format": options.page_size,
        "landscape": options.landscape,
        "print_background": options.print_background,
        "margin": {
            "top": options.margins.top,
            "right": options.margins.right,
            "bottom": options.margins.bottom,
            "left": options.margins.left,
        },
    }
    if options.header_template or options.footer_template:
        kwargs["display_header_footer"] = True
        kwargs["header_template"] = options.header_template or "<span></span>"
        kwargs["footer_template"] = options.footer_template or "<span></span>"
    return kwargs


async def _capture_preview(page, target: Path) -> str | None:
    """Screenshot the rendered page (print media) into a downscaled PNG sibling.

    Returns the preview path, or None if the screenshot/encode failed. A single
    small raster is dramatically cheaper to read back than the full PDF (which
    re-ingests every page as a high-res image).
    """
    try:
        await page.emulate_media(media="print")
        png_bytes = await page.screenshot(full_page=True)
    except Exception:
        return None
    preview = target.with_suffix(".preview.png")
    try:
        import io

        from PIL import Image

        img = Image.open(io.BytesIO(png_bytes))
        # Bound the longest side so a long doc doesn't produce a huge thumbnail.
        scale = min(1.0, 1000 / img.width, 3000 / img.height)
        if scale < 1.0:
            img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))))
        img.save(preview, format="PNG")
    except Exception:
        preview.write_bytes(png_bytes)  # fall back to the full-res screenshot
    return str(preview)


async def _render_pdf(
    html: str, base_url: str | None, options: PdfOptions, target: Path
) -> tuple[int, list[str], str | None]:
    from docgen.server import get_browser
    import os
    import tempfile

    browser = await get_browser()
    context = await browser.new_context()
    asset_warnings: list[str] = []
    preview_path: str | None = None
    tmp_path: str | None = None
    try:
        page = await context.new_page()

        # Collect every subresource that fails. Silent broken-asset renders
        # (most common cause: relative <img src> not resolving) cost a lot
        # of debugging time, so we surface every failure to the caller.
        def _on_response(resp):
            try:
                if resp.status >= 400 and resp.url != page.url:
                    asset_warnings.append(f"{resp.status} {resp.url}")
            except Exception:
                pass

        def _on_requestfailed(req):
            try:
                asset_warnings.append(f"FAILED {req.url} ({req.failure})")
            except Exception:
                pass

        page.on("response", _on_response)
        page.on("requestfailed", _on_requestfailed)

        if base_url:
            # set_content() leaves the page URL at about:blank, which Chromium
            # treats as a privileged origin that cannot load file:// subresources
            # (images, CSS url(...)). Write the HTML to a temp file inside the
            # base directory and load via file:// so sibling assets resolve.
            base_dir = base_url[len("file://"):].rstrip("/") if base_url.startswith("file://") else base_url
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".html", dir=base_dir, delete=False, encoding="utf-8"
            ) as fh:
                fh.write(html)
                tmp_path = fh.name
            await page.goto(f"file://{tmp_path}", wait_until="networkidle")
        else:
            await page.set_content(html, wait_until="networkidle")

        pdf_bytes = await page.pdf(**_playwright_pdf_kwargs(options))
        if options.preview:
            preview_path = await _capture_preview(page, target)
    finally:
        if tmp_path is not None:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        await context.close()

    target.write_bytes(pdf_bytes)
    return len(pdf_bytes), asset_warnings, preview_path


def register_pdf_tools(server: FastMCP) -> None:
    @server.tool(
        name="pdf_from_html",
        description=(
            "Render HTML/CSS to a PDF via headless Chromium. "
            "html_or_path may be an inline HTML string or a path to an .html file. "
            "Set options.base_dir to resolve relative asset paths (images, CSS url(...)). "
            "Set options.markdown=true to interpret the input as Markdown.\n"
            "ITERATION: if you expect to revise this document (most real docs go through "
            "several rounds), FIRST write the HTML/Markdown to a .html/.md file, then call "
            "this tool with the file PATH and Edit the file between renders. Passing inline "
            "HTML re-sends the entire document on every render (often thousands of tokens); "
            "rendering by path costs ~50. Pass options.save_source=true on a first inline "
            "render to have the source persisted for you (returned as source_path). "
            "Returns page_count so you can confirm pagination without opening the PDF; pass "
            "options.preview=true for a small preview_path image to check layout cheaply "
            "instead of reading the full PDF back."
        ),
    )
    async def pdf_from_html(
        html_or_path: Annotated[str, Field(description="Inline HTML, Markdown, or path to an .html file")],
        output_path: Annotated[str, Field(description="Destination path; relative paths land in DOCGEN_OUTPUT_DIR (default ~/.local/share/docgen/output)")],
        css: Annotated[str, Field(description="Optional CSS injected into <head>")] = "",
        options: PdfOptions | dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        try:
            opts = PdfOptions.model_validate(options) if options else PdfOptions()
        except Exception as e:  # noqa: BLE001
            return err(f"Invalid options: {e}")
        try:
            target = resolve_output_path(output_path, overwrite=opts.overwrite)
            html, base_url, from_path = _build_html(html_or_path, css, opts)
            bytes_written, asset_warnings, preview_path = await _render_pdf(html, base_url, opts, target)
            if asset_warnings and opts.strict_assets:
                target.unlink(missing_ok=True)
                return err(
                    "strict_assets enabled and one or more assets failed to load: "
                    + "; ".join(asset_warnings)
                )
            result = ok(path=str(target), bytes_written=bytes_written)
            try:
                from pypdf import PdfReader

                result["page_count"] = len(PdfReader(str(target)).pages)
            except Exception:  # noqa: BLE001 — page_count is best-effort, never fatal
                pass
            if asset_warnings:
                result["asset_warnings"] = asset_warnings
            if preview_path:
                result["preview_path"] = preview_path
            # Persist inline source on request, and always nudge the cheap iteration
            # path when a large document was sent inline (the dominant token sink).
            if not from_path:
                if opts.save_source:
                    suffix = ".md" if opts.markdown else ".html"
                    source = target.with_suffix(f".source{suffix}")
                    source.write_text(html_or_path, encoding="utf-8")
                    result["source_path"] = str(source)
                if len(html_or_path) > 2000 and not opts.save_source:
                    result["hint"] = (
                        "Rendered from inline HTML (%d chars). To iterate cheaply, write this "
                        "to a .html file and re-render by PATH (editing the file between rounds), "
                        "or pass options.save_source=true to have it persisted." % len(html_or_path)
                    )
            return result
        except PathError as e:
            return err(str(e))
        except Exception as e:  # noqa: BLE001 — surface Playwright/render failures cleanly
            return err(f"{type(e).__name__}: {e}")

    @server.tool(
        name="pdf_merge",
        description="Concatenate PDFs in order into a single output PDF.",
    )
    async def pdf_merge(
        input_paths: Annotated[list[str], Field(description="Paths to PDFs to merge, in order")],
        output_path: Annotated[str, Field(description="Destination path; relative paths land in DOCGEN_OUTPUT_DIR (default ~/.local/share/docgen/output)")],
        overwrite: bool = True,
    ) -> dict[str, Any]:
        from pypdf import PdfWriter

        try:
            if not input_paths:
                return err("input_paths is empty")
            sources = [resolve_input_path(p) for p in input_paths]
            target = resolve_output_path(output_path, overwrite=overwrite)
        except PathError as e:
            return err(str(e))

        writer = PdfWriter()
        try:
            for src in sources:
                writer.append(str(src))
            with target.open("wb") as fh:
                writer.write(fh)
        except Exception as e:  # noqa: BLE001
            return err(f"{type(e).__name__}: {e}")
        finally:
            writer.close()

        return ok(path=str(target), bytes_written=target.stat().st_size, page_count=len(writer.pages) if hasattr(writer, "pages") else None)

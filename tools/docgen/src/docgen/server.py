"""FastMCP entrypoint for docgen.

Boots one Chromium instance lazily on first PDF call and reuses it across renders
(closed on server shutdown). Tool registration is split into small `register_*`
functions to mirror the pattern in `nexus/src/server.ts`.
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Any

from mcp.server.fastmcp import FastMCP

_browser_lock = asyncio.Lock()
_browser: Any = None
_playwright: Any = None


async def get_browser() -> Any:
    """Return the shared Chromium instance, launching it on first call."""
    global _browser, _playwright
    if _browser is not None:
        return _browser
    async with _browser_lock:
        if _browser is None:
            from playwright.async_api import async_playwright

            _playwright = await async_playwright().start()
            _browser = await _playwright.chromium.launch()
    return _browser


async def shutdown_browser() -> None:
    global _browser, _playwright
    if _browser is not None:
        await _browser.close()
        _browser = None
    if _playwright is not None:
        await _playwright.stop()
        _playwright = None


@asynccontextmanager
async def lifespan(_: FastMCP):
    try:
        yield {}
    finally:
        await shutdown_browser()


mcp = FastMCP("docgen", lifespan=lifespan)


def main() -> None:
    from docgen.pdf import register_pdf_tools
    from docgen.docx_build import register_docx_build_tools
    from docgen.docx_tpl import register_docx_tpl_tools

    register_pdf_tools(mcp)
    register_docx_build_tools(mcp)
    register_docx_tpl_tools(mcp)

    mcp.run()


if __name__ == "__main__":
    main()

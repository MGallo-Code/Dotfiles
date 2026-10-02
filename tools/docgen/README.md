# docgen

MCP server that generates DOCX and PDF files. It lives in dotfiles (`tools/docgen/`, ADR-0007) so every machine runs it locally; setup and sync install it and wire it into Claude, Codex and Gemini.

## Tools

| Tool | Purpose |
| --- | --- |
| `pdf_from_html` | Render HTML/CSS (or Markdown via `options.markdown=true`, or an `.html` file path) to PDF via headless Chromium. Set `options.base_dir` so relative images and `url(...)` references resolve — the renderer writes a temp HTML file inside `base_dir` and loads it via `file://` so sibling assets are reachable from Chromium's loader. Subresource fetch failures (missing image, 404 CSS) come back in the response as `asset_warnings`; set `options.strict_assets=true` to fail the render instead. Returns `page_count`. Set `options.preview=true` for a downscaled `preview_path` PNG, and `options.save_source=true` to persist inline source as `source_path`. See "Iterating efficiently" below. |
| `pdf_merge` | Concatenate input PDFs in order into a single file. |
| `docx_from_template` | Fill a `.docx` Jinja2 template (docxtpl). Image placeholders take `{"path": "...", "width_mm": N}` dicts. |
| `docx_create_from_spec` | Build a `.docx` from a typed block list (heading / paragraph / list / table / image / page_break). Pass `reference_doc` to seed styles from a brand template. |
| `inspect_docx_template` | List the Jinja2 variables a `.docx` template expects. Run before `docx_from_template` to discover required context keys. |

All tools return `{"ok": true, "path": "...", "bytes_written": N, ...}` on success or `{"ok": false, "error": "..."}` on failure.

## Iterating efficiently (token cost)

The dominant cost when generating documents is **re-sending the full HTML on every render**. A real evidence doc goes through 5–12 revisions; each inline render re-transmits the whole document (often 6k+ tokens). The fix:

- **Write the HTML/Markdown to a file first, then render by PATH and `Edit` the file between rounds.** A path render costs ~50 tokens regardless of document size; an inline render costs ~`len(html)/4`. Across a 12-round edit loop that is the difference between ~1k and ~75k tokens. (On a first inline render, pass `options.save_source=true` and the tool persists the source for you as `source_path` so you can switch to the file-based loop immediately.)
- **Don't read the PDF back to "check" it.** Reading a PDF re-ingests every page as a high-res image. Instead: trust the deterministic render, use the returned `page_count` to confirm pagination, and pass `options.preview=true` to get a single small `preview_path` PNG for a visual sanity check.
- **Prefer `options.markdown=true` on a `.md` file** for text-heavy docs — far more compact and editable than hand-written HTML.

## Path semantics

- Relative `output_path` resolves against `DOCGEN_OUTPUT_DIR` (default `~/.local/share/docgen/output`). Generated files never land inside this checkout: dotfiles is public.
- Absolute `output_path` must land inside one of: `/tmp/`, the system temp dir, or anywhere under the user's home directory (`~/`). Anything else (system paths like `/etc`, `/usr`, other users' homes) returns an error.
- Existing files are overwritten by default. Set `overwrite=false` (or `options.overwrite=false` for PDF) to refuse.

## Layout

```
docgen/
├── src/docgen/        # server.py + per-domain modules
├── tests/             # pytest suite
└── pyproject.toml
```

Chromium lives outside the checkout, in `~/.cache/docgen-playwright` (`PLAYWRIGHT_BROWSERS_PATH`).

## Setup

`setup` and `sync` do it on every machine: `uv sync` here, Chromium into `~/.cache/docgen-playwright`, and the global MCP entry (the `docgen` hub in `manifest.sh` / `manifest.ps1`). MCP spawns commands via `execvp`, so the entry carries absolute paths and sets `PYTHONPATH=src` (Python 3.12 skips the `_*.pth` editable-install file hatchling generates).

By hand:

```bash
cd ~/.dotfiles/tools/docgen
uv sync
PLAYWRIGHT_BROWSERS_PATH=~/.cache/docgen-playwright uv run playwright install chromium
```

## Running tests

```bash
# DOCX + path tests (fast)
.venv/bin/python -m pytest tests/test_paths.py tests/test_docx_build.py tests/test_docx_tpl.py -v

# PDF tests (opt-in, requires Chromium and is slow)
PLAYWRIGHT_BROWSERS_PATH=~/.cache/docgen-playwright .venv/bin/python -m pytest tests/test_pdf.py -v --slow
```

On Windows: substitute `.venv\Scripts\python.exe` and `$env:PLAYWRIGHT_BROWSERS_PATH = "$HOME\.cache\docgen-playwright"`.

PDF behavior is also verifiable via a direct asyncio smoke script — see git history for the inline one used during v0 bring-up. The pytest path for PDF is wired but interacts awkwardly with `pytest-asyncio`'s session-loop handling on this version; use the direct script if pytest hangs.

## Known limitations (v0)

- Table cells in `docx_create_from_spec` are strings only — no multi-paragraph cells.
- No `docx_to_pdf` conversion. (LibreOffice not installed; `docx2pdf` has fidelity and focus-steal issues. Build PDFs from HTML directly, or open the `.docx` in Word and Export.)
- No section breaks / mixed page orientation in `docx_create_from_spec`. `page_break` is page-level only.
- No TOC generation.

## Design notes

- One Chromium instance is launched lazily on first PDF call and reused across renders. Closed cleanly on server shutdown.
- All inputs validated with Pydantic models in `src/docgen/models.py`.
- Mirrors Nexus's `register_*_tools(server)` pattern: one module per domain, server entry registers them in sequence.

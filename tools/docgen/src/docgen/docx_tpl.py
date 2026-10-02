"""Word-template filling via docxtpl (Jinja2 inside .docx)."""

from __future__ import annotations

from typing import Annotated, Any

from docxtpl import DocxTemplate, InlineImage
from docx.shared import Mm
from mcp.server.fastmcp import FastMCP
from pydantic import Field

from docgen.paths import PathError, resolve_input_path, resolve_output_path
from docgen.utils import err, ok


def _coerce_inline_images(tpl: DocxTemplate, context: dict[str, Any]) -> dict[str, Any]:
    """Walk the context and replace `{path, width_mm}` dicts with InlineImage instances."""

    def coerce(value: Any) -> Any:
        if isinstance(value, dict):
            if "path" in value and ("width_mm" in value or "image" in value):
                path = resolve_input_path(value["path"])
                width = value.get("width_mm")
                return InlineImage(tpl, str(path), width=Mm(width) if width else None)
            return {k: coerce(v) for k, v in value.items()}
        if isinstance(value, list):
            return [coerce(v) for v in value]
        return value

    return {k: coerce(v) for k, v in context.items()}


def register_docx_tpl_tools(server: FastMCP) -> None:
    @server.tool(
        name="docx_from_template",
        description=(
            "Fill a Word template (.docx with Jinja2 placeholders) with the given context "
            "and write the result to output_path. To embed an image at a placeholder, pass "
            'a dict like {"path": "/abs/path/logo.png", "width_mm": 40} as the variable value.'
        ),
    )
    async def docx_from_template(
        template_path: Annotated[str, Field(description="Path to the .docx template")],
        context: Annotated[dict[str, Any], Field(description="Jinja2 context. Image placeholders take {path, width_mm} dicts.")],
        output_path: Annotated[str, Field(description="Destination .docx path")],
        overwrite: bool = True,
    ) -> dict[str, Any]:
        try:
            src = resolve_input_path(template_path)
            target = resolve_output_path(output_path, overwrite=overwrite)
        except PathError as e:
            return err(str(e))

        try:
            tpl = DocxTemplate(str(src))
            rendered_context = _coerce_inline_images(tpl, context)
            tpl.render(rendered_context)
            tpl.save(str(target))
        except PathError as e:
            return err(str(e))
        except Exception as e:  # noqa: BLE001
            return err(f"{type(e).__name__}: {e}")

        return ok(path=str(target), bytes_written=target.stat().st_size)

    @server.tool(
        name="inspect_docx_template",
        description=(
            "Return the list of Jinja2 variables a .docx template expects. "
            "Use this before docx_from_template to discover what keys to pass in context."
        ),
    )
    async def inspect_docx_template(
        template_path: Annotated[str, Field(description="Path to the .docx template")],
    ) -> dict[str, Any]:
        try:
            src = resolve_input_path(template_path)
        except PathError as e:
            return err(str(e))

        try:
            tpl = DocxTemplate(str(src))
            variables = sorted(tpl.get_undeclared_template_variables())
        except Exception as e:  # noqa: BLE001
            return err(f"{type(e).__name__}: {e}")

        return ok(undeclared_variables=variables)

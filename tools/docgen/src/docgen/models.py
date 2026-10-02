from typing import Annotated, Any, Literal

from pydantic import BaseModel, Field

PageSize = Literal["Letter", "A4", "Legal"]
Align = Literal["left", "center", "right", "justify"]


class Margins(BaseModel):
    top: str = "0.75in"
    right: str = "0.75in"
    bottom: str = "0.75in"
    left: str = "0.75in"


class PdfOptions(BaseModel):
    page_size: PageSize = "Letter"
    margins: Margins = Field(default_factory=Margins)
    landscape: bool = False
    print_background: bool = True
    header_template: str | None = None
    footer_template: str | None = None
    base_dir: str | None = Field(
        default=None,
        description=(
            "Directory to resolve relative asset paths (images, CSS url(...)) against. "
            "Required when html_or_path references local files by relative path."
        ),
    )
    markdown: bool = False
    overwrite: bool = True
    strict_assets: bool = Field(
        default=False,
        description=(
            "If true, fail the render when any image/CSS/font asset fails to load "
            "(404 or request error). Default surfaces failures as an `asset_warnings` "
            "list in the response but still writes the PDF."
        ),
    )
    preview: bool = Field(
        default=False,
        description=(
            "If true, also write a downscaled PNG raster of the rendered page next to "
            "the PDF and return its path as `preview_path`. Read that one small image to "
            "verify layout/content instead of re-ingesting the whole multi-page PDF "
            "(which renders every page as a separate high-res image — far more tokens)."
        ),
    )
    save_source: bool = Field(
        default=False,
        description=(
            "If true and html_or_path was inline HTML/Markdown, persist the rendered "
            "source next to the PDF and return its path as `source_path`. Then iterate by "
            "Editing that file and re-rendering by PATH (≈50 tokens/render) instead of "
            "re-sending the full document inline every time (thousands of tokens/render)."
        ),
    )


class InlineStyle(BaseModel):
    bold: bool | None = None
    italic: bool | None = None
    align: Align | None = None
    size_pt: float | None = None


class HeadingBlock(BaseModel):
    type: Literal["heading"]
    level: Annotated[int, Field(ge=1, le=6)]
    text: str
    style_name: str | None = None


class ParagraphBlock(BaseModel):
    type: Literal["paragraph"]
    text: str
    style_name: str | None = None
    style: InlineStyle | None = None


class ListBlock(BaseModel):
    type: Literal["list"]
    items: list[str]
    ordered: bool = False


class TableBlock(BaseModel):
    type: Literal["table"]
    rows: list[list[str]]
    header: bool = False


class ImageBlock(BaseModel):
    type: Literal["image"]
    path: str
    width_in: float | None = None


class PageBreakBlock(BaseModel):
    type: Literal["page_break"]


Block = Annotated[
    HeadingBlock | ParagraphBlock | ListBlock | TableBlock | ImageBlock | PageBreakBlock,
    Field(discriminator="type"),
]


class DocxSpec(BaseModel):
    blocks: list[Block]
    metadata: dict[str, Any] | None = None

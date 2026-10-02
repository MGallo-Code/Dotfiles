import os
import tempfile
from pathlib import Path

DOCGEN_ROOT = Path(__file__).resolve().parent.parent.parent
# Generated documents never land inside the code checkout: dotfiles is a public repo
# (ADR-0007). DOCGEN_OUTPUT_DIR overrides the default.
DEFAULT_OUTPUT_DIR = Path(
    os.environ.get("DOCGEN_OUTPUT_DIR") or "~/.local/share/docgen/output"
).expanduser()

ALLOWED_ROOTS: tuple[Path, ...] = (
    Path("/tmp").resolve(),
    Path(tempfile.gettempdir()).resolve(),
    Path.home().resolve(),
)


class PathError(ValueError):
    pass


def resolve_output_path(output_path: str, *, overwrite: bool = True) -> Path:
    """Resolve user-supplied output_path.

    - Relative paths resolve against DEFAULT_OUTPUT_DIR.
    - Absolute paths must land inside ALLOWED_ROOTS after symlink resolution.
    - Parent directory is created if missing.
    - Refuses to overwrite when overwrite=False and the file already exists.
    """
    raw = Path(output_path).expanduser()
    candidate = raw if raw.is_absolute() else (DEFAULT_OUTPUT_DIR / raw)
    resolved = candidate.resolve()

    if not any(_is_within(resolved, root) for root in ALLOWED_ROOTS):
        roots = ", ".join(str(r) for r in ALLOWED_ROOTS)
        raise PathError(
            f"Output path {resolved} is outside allowed roots ({roots})."
        )

    if resolved.exists() and not overwrite:
        raise PathError(f"Refusing to overwrite existing file: {resolved}")

    resolved.parent.mkdir(parents=True, exist_ok=True)
    return resolved


def resolve_input_path(input_path: str) -> Path:
    """Resolve user-supplied input file path; must exist and live in an allowed root."""
    resolved = Path(input_path).expanduser().resolve()
    if not resolved.exists():
        raise PathError(f"Input path does not exist: {resolved}")
    if not any(_is_within(resolved, root) for root in ALLOWED_ROOTS):
        roots = ", ".join(str(r) for r in ALLOWED_ROOTS)
        raise PathError(
            f"Input path {resolved} is outside allowed roots ({roots})."
        )
    return resolved


def resolve_base_dir(base_dir: str) -> Path:
    """Resolve a base directory used as a render's file:// origin AND temp-write dir.

    This is the chokepoint that keeps PdfOptions.base_dir from escaping the sandbox:
    _render_pdf writes a temp .html INTO this directory and serves it via file://, so an
    unchecked base_dir is an arbitrary-write + arbitrary-read primitive. The directory
    must resolve (after symlink resolution) inside ALLOWED_ROOTS and must already exist.
    """
    resolved = Path(base_dir).expanduser().resolve()
    if not any(_is_within(resolved, root) for root in ALLOWED_ROOTS):
        roots = ", ".join(str(r) for r in ALLOWED_ROOTS)
        raise PathError(f"base_dir {resolved} is outside allowed roots ({roots}).")
    if not resolved.is_dir():
        raise PathError(f"base_dir does not exist or is not a directory: {resolved}")
    return resolved


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False

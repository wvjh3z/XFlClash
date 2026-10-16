#!/usr/bin/env python3
"""Render public flavor system icons for review and commit; never run in CI.

Requires an author-installed Python Playwright and Chromium. Set
PLAYWRIGHT_BROWSERS_PATH or pass --browser-executable for a local browser.
The runtime/build preparation only copies and verifies these rendered files.

Examples:
  python tool/generate_system_icons.py --flavor brand_a
  python tool/generate_system_icons.py --flavor brand_b --check
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import xml.etree.ElementTree as ET


BADGE_COLORS = {
    "status_1": "#E5A14B",
    "status_2": "#12B8A6",
    "status_3": "#4B8FE8",
}
ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
ANDROID_SIZES = {
    "drawable": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}
ANDROID_ALIASES = b'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <item type="drawable" name="ic">@drawable/xb_brand_system_icon</item>
    <item type="drawable" name="ic_service">@drawable/xb_brand_system_icon</item>
</resources>
'''

# Native resolution rendering preserves the approved preview's bottom-right
# white-ring badges. Small Windows frames use the preview's 18px sample ratio.
RENDER_JS = """async ({colorSource, monochromeSource, requests}) => {
  async function decode(src) {
    const image = new Image();
    image.src = src;
    await image.decode();
    return image;
  }
  const color = await decode(colorSource);
  const mono = await decode(monochromeSource);
  const outputs = [];
  for (const request of requests) {
    const {size, kind, badge} = request;
    const canvas = document.createElement('canvas');
    canvas.width = size;
    canvas.height = size;
    const context = canvas.getContext('2d');
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = 'high';
    const image = kind === 'color' ? color : mono;
    // The preview uses object-fit: contain. Retain source aspect ratio.
    const box = kind === 'color' ? size * 100 / 104 : size;
    const scale = box / Math.max(image.naturalWidth, image.naturalHeight);
    const width = image.naturalWidth * scale;
    const height = image.naturalHeight * scale;
    context.drawImage(image, (box - width) / 2, (box - height) / 2, width, height);
    if (kind === 'white') {
      context.globalCompositeOperation = 'source-in';
      context.fillStyle = '#FFFFFF';
      context.fillRect(0, 0, size, size);
      context.globalCompositeOperation = 'source-over';
    }
    if (badge) {
      const ratio = size <= 40 ? 1 / 3 : 0.27;
      const outer = box * ratio;
      const border = box * (size <= 40 ? 1 / 18 : 2.5 / 64);
      const center = box * 1.02 - outer / 2;
      context.beginPath();
      context.arc(center, center, (outer - border) / 2, 0, Math.PI * 2);
      context.fillStyle = badge;
      context.fill();
      context.strokeStyle = '#FFFFFF';
      context.lineWidth = border;
      context.stroke();
    }
    const pixels = context.getImageData(0, 0, size, size).data;
    let visible = 0, transparent = 0, wrongMono = 0;
    for (let n = 0; n < pixels.length; n += 4) {
      if (pixels[n + 3]) {
        visible++;
        if (kind !== 'color') {
          const expected = kind === 'white' ? 255 : 0;
          if (pixels[n] !== expected || pixels[n+1] !== expected ||
              pixels[n+2] !== expected) wrongMono++;
        }
      } else transparent++;
    }
    if (!visible || !transparent || wrongMono) {
      throw new Error(`Invalid ${kind} ${size}px alpha/monochrome pixels`);
    }
    outputs.push(canvas.toDataURL('image/png').split(',')[1]);
  }
  return outputs;
}"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def data_url(mime: str, data: bytes) -> str:
    return f"data:{mime};base64," + base64.b64encode(data).decode("ascii")


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("Expected a PNG with an IHDR header")
    width, height = struct.unpack_from(">II", data, 16)
    if not width or not height:
        raise ValueError("PNG dimensions must be positive")
    return width, height


def validate_monochrome(data: bytes) -> None:
    """Only self-contained SVG sources may enter the offline renderer."""
    svg = ET.fromstring(data)
    if svg.tag != "{http://www.w3.org/2000/svg}svg":
        raise ValueError("monochrome.svg must contain an SVG root")
    for element in svg.iter():
        if element.tag.rsplit("}", 1)[-1] in {"script", "foreignObject", "style"}:
            raise ValueError("SVG must contain only static self-contained artwork")
        for name, value in element.attrib.items():
            if name.lower().startswith("on"):
                raise ValueError("SVG event attributes are not allowed")
            if name.rsplit("}", 1)[-1] == "href" and not value.startswith(
                ("data:image/png;base64,", "#")
            ):
                raise ValueError("SVG image references must be embedded PNGs")
            if "url(" in value and not value.startswith("url(#"):
                raise ValueError("SVG URL references must be local fragments")


def make_ico(frames: dict[int, bytes]) -> bytes:
    """Pack PNG frames into a Windows ICO using only the standard library."""
    offset = 6 + 16 * len(frames)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    payload = bytearray()
    for size, png in frames.items():
        if png_size(png) != (size, size):
            raise ValueError(f"Incorrect {size}px ICO frame")
        directory.extend(struct.pack(
            "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset
        ))
        payload.extend(png)
        offset += len(png)
    return bytes(directory + payload)


def generate(project: Path, brand: str, browser_executable: str | None) -> dict[str, bytes]:
    source_dir = project / "flavors" / brand
    color = (source_dir / "assets" / "icons" / f"{brand}.png").read_bytes()
    monochrome = (source_dir / "system_icons" / "monochrome.svg").read_bytes()
    png_size(color)
    validate_monochrome(monochrome)

    # Import only for this optional authoring command. No dependency is added to
    # Flutter, pubspec, or the production resource-copying pipeline.
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        raise RuntimeError("Use an author environment with Python Playwright installed") from error

    requests = []
    for state, badge in BADGE_COLORS.items():
        for size in ICO_SIZES:
            requests.append({"path": f"windows/{state}.ico", "size": size,
                             "kind": "color", "badge": badge})
        requests.append({"path": f"linux/{state}.png", "size": 108,
                         "kind": "color", "badge": badge})
    requests.append({"path": "macos/status_1.png", "size": 128, "kind": "black"})
    for density, size in ANDROID_SIZES.items():
        requests.append({"path": f"android/{density}/xb_brand_system_icon.png",
                         "size": size, "kind": "white"})

    with sync_playwright() as playwright:
        options = {"headless": True}
        if browser_executable:
            options["executable_path"] = browser_executable
        browser = playwright.chromium.launch(**options)
        try:
            page = browser.new_page()
            page.route("**/*", lambda route: route.abort())
            encoded = page.evaluate(RENDER_JS, {
                "colorSource": data_url("image/png", color),
                "monochromeSource": data_url("image/svg+xml", monochrome),
                "requests": requests,
            })
        finally:
            browser.close()

    files: dict[str, bytes] = {}
    frames: dict[str, dict[int, bytes]] = {}
    metadata = {}
    for request, result in zip(requests, encoded, strict=True):
        png = base64.b64decode(result, validate=True)
        size = request["size"]
        if png_size(png) != (size, size):
            raise ValueError(f"Incorrect generated dimensions: {request['path']}")
        path = request["path"]
        if path.endswith(".ico"):
            frames.setdefault(path, {})[size] = png
        else:
            files[path] = png
            metadata[path] = {"width": size, "height": size}
    for path, png_frames in frames.items():
        files[path] = make_ico(png_frames)
        metadata[path] = {"width": 256, "height": 256, "sizes": list(png_frames)}

    manifest = {
        "schema": 1,
        "brand": brand,
        "source": {"color_sha256": sha256(color), "monochrome_sha256": sha256(monochrome)},
        "badge_colors": BADGE_COLORS,
        "files": {
            path: {"sha256": sha256(data), "bytes": len(data), **metadata[path]}
            for path, data in sorted(files.items())
        },
    }
    files["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flavor", required=True, choices=("brand_a", "brand_b"))
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--browser-executable")
    parser.add_argument("--check", action="store_true", help="render and compare without writing project files")
    args = parser.parse_args()
    try:
        project = args.project_root.resolve(strict=True)
        generated = generate(project, args.flavor, args.browser_executable)
        output = project / "flavors" / args.flavor / "system_icons"
        destinations = {output / path: data for path, data in generated.items()}
        android = project / "android" / "app" / "src" / args.flavor / "res"
        for density in ANDROID_SIZES:
            name = f"{density}/xb_brand_system_icon.png"
            destinations[android / name] = generated[f"android/{name}"]
        destinations[android / "values" / "xb_system_icons.xml"] = ANDROID_ALIASES
        if args.check:
            different = [str(path.relative_to(project)) for path, data in destinations.items()
                         if not path.is_file() or path.read_bytes() != data]
            if different:
                raise ValueError("Resources differ; regenerate and review: " + ", ".join(different))
            print(f"{args.flavor}: {len(generated) - 1} system icons, manifest, and Android copies match")
        else:
            # Render and validate the entire set before changing any project
            # output. Stage beside the destination for atomic per-file replace.
            with tempfile.TemporaryDirectory(prefix=".system-icons-", dir=output.parent) as temporary:
                stage = Path(temporary)
                for path, data in destinations.items():
                    target = stage / path.relative_to(project)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                for path in destinations:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    (stage / path.relative_to(project)).replace(path)
            print(f"{args.flavor}: wrote {len(generated) - 1} system icons, manifest, and Android copies")
        return 0
    except Exception as error:
        print(f"System icon generation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

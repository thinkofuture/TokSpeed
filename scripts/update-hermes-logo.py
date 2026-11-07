#!/usr/bin/env python3
"""Bundle the pinned official Nous Girl artwork using the app's SVG subset.

Uses only the Python standard library. Coordinates and the uniform source
transform are retained; editor metadata and unused clipping definitions are not.
"""

from decimal import Decimal
from pathlib import Path
import hashlib
import re
import urllib.request
import xml.etree.ElementTree as ET


REVISION = "1fa5fea74f69566196707c7039c35c26155cfb9d"
SOURCE = f"https://raw.githubusercontent.com/NousResearch/hermes-agent/{REVISION}/assets/nous-girl-black.svg"
NUMBER = r"[-+]?(?:\d*\.)?\d+(?:[eE][-+]?\d+)?"
TOKEN = re.compile(r"[MLCZz]|" + NUMBER)


def main():
    data = urllib.request.urlopen(SOURCE, timeout=30).read()
    root = ET.fromstring(data)
    paths = root.findall(".//{http://www.w3.org/2000/svg}path")
    if len(paths) != 1:
        raise ValueError("Expected the official single-path Nous Girl artwork")
    source = paths[0]
    transform = source.get("transform", "")
    if not re.fullmatch(r"matrix\([\d.,\s-]+\)", transform):
        raise ValueError("Unexpected source transform")
    a, b, c, d, e, f = map(Decimal, re.findall(NUMBER, transform))
    if b != 0 or c != 0 or a != d or a <= 0:
        raise ValueError("Expected a uniform positive source transform")

    text = source.attrib["d"]
    if TOKEN.sub("", text).strip(" \t\r\n,"):
        raise ValueError("Unexpected SVG path command")
    tokens = TOKEN.findall(text)
    index = 0
    command = None
    result = []

    def coordinate(value):
        value = value.quantize(Decimal("0.000001"))
        return "0" if value == 0 else format(value.normalize(), "f")

    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index].upper()
            index += 1
        if command == "Z":
            result.append("Z")
            command = None
            continue
        count = {"M": 1, "L": 1, "C": 3}.get(command)
        if count is None:
            raise ValueError("Missing or unsupported path command")
        points = []
        for _ in range(count):
            x, y = map(Decimal, tokens[index:index + 2])
            index += 2
            points.append(coordinate(a * x + e) + " " + coordinate(d * y + f))
        result.append(command + " ".join(points))
        if command == "M":
            command = "L"

    artwork = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="' + root.attrib["viewBox"]
               + '"><path fill="white" d="' + "".join(result) + '"/></svg>\n')
    output = Path(__file__).resolve().parent.parent / "Resources/Logos/hermes.svg"
    output.write_text(artwork, encoding="utf-8")
    print("Source revision:", REVISION)
    print("Source SVG SHA-256:", hashlib.sha256(data).hexdigest())
    print("Bundled:", output)


if __name__ == "__main__":
    main()

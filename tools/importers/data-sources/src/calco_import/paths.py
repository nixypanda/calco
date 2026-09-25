"""Shared filesystem paths for the catalog importer.

Kept separate from ``calco_import.fetch`` so the fetch submodules can import
``MAPPING_DIR`` without creating an import cycle through the package
``__init__``.
"""

import os

MAPPING_DIR = os.path.join(
    os.path.dirname(__file__),
    "..",
    "..",
    "nutrient_mapping",
)

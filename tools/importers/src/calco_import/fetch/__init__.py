import os

MAPPING_DIR = os.path.join(
    os.path.dirname(__file__), "..", "..", "..", "nutrient_mapping",
)

from calco_import.fetch.ifct import fetch_ifct  # noqa: E402
from calco_import.fetch.indb import fetch_indb  # noqa: E402
from calco_import.fetch.off import fetch_off  # noqa: E402
from calco_import.fetch.usda import fetch_usda  # noqa: E402


def dispatch(data_dir: str, dataset: str) -> None:
    if dataset == "usda":
        fetch_usda(data_dir)
    elif dataset == "off":
        fetch_off(data_dir)
    elif dataset == "ifct":
        fetch_ifct(data_dir)
    elif dataset == "indb":
        fetch_indb(data_dir)

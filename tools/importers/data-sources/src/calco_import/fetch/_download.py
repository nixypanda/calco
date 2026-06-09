import logging
import os

import requests
import tqdm

log = logging.getLogger(__name__)


def download_file(url: str, dest: str) -> None:
    if os.path.exists(dest):
        log.info("File already exists at %s, skipping download", dest)
        return
    log.info("Downloading %s ...", url)
    resp = requests.get(
        url,
        stream=True,
        timeout=300,
        headers={
            "User-Agent": "CalCo/1.0",
        },
    )
    resp.raise_for_status()
    total = int(resp.headers.get("content-length", 0))
    with (
        open(dest, "wb") as f,
        tqdm.tqdm(
            total=total,
            unit="B",
            unit_scale=True,
            desc=os.path.basename(dest),
        ) as pbar,
    ):
        for chunk in resp.iter_content(chunk_size=8192):
            if chunk:
                f.write(chunk)
                pbar.update(len(chunk))

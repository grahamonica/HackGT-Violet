"""Registry of source-dataset adapters.

Each adapter module exposes:
    prepare(cfg)                      -> writes work/source_images.csv (generic columns)
    materialize(cfg, source_paths)    -> ensures those source images exist on disk
"""

from . import prepare_celeba

SOURCES = {"celeba": prepare_celeba}

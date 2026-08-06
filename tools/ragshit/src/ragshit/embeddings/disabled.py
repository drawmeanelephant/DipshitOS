"""Disabled embedding provider.

Config ``[embeddings] enabled = false`` (the default) selects this
provider. Any attempt to actually embed raises a clear error; the rest of
Ragshit never calls it.
"""

from __future__ import annotations

from typing import Sequence

from ..errors import EmbeddingError


class DisabledProvider:
    @property
    def dimensions(self) -> int:
        raise EmbeddingError(
            "embeddings are disabled (provider 'disabled'); "
            "enable an embedding provider in .ragshit.toml first"
        )

    def embed(self, texts: Sequence[str]) -> Sequence[Sequence[float]]:
        raise EmbeddingError(
            "embeddings are disabled (provider 'disabled'); "
            "enable an embedding provider in .ragshit.toml first"
        )

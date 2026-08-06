"""Embeddings: interface + disabled provider. No network in milestone zero."""

from __future__ import annotations

from .base import EmbeddingProvider, ProviderRegistry
from .disabled import DisabledProvider

registry = ProviderRegistry()
registry.register("disabled", lambda: DisabledProvider())


def get_provider(name: str = "disabled") -> EmbeddingProvider:
    """Return a provider instance; raises EmbeddingError for unknown names."""
    return registry.create(name)


__all__ = ["EmbeddingProvider", "ProviderRegistry", "DisabledProvider", "registry", "get_provider"]

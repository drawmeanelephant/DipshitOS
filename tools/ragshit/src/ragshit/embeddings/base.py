"""Embedding provider interface.

Milestone zero ships only the disabled provider; real providers are future
work (see docs/roadmap.md). The indexing and retrieval pipeline must never
depend on embeddings.
"""

from __future__ import annotations

from typing import Dict, Protocol, Sequence

from ..errors import EmbeddingError


class EmbeddingProvider(Protocol):
    @property
    def dimensions(self) -> int: ...

    def embed(self, texts: Sequence[str]) -> Sequence[Sequence[float]]: ...


class ProviderRegistry:
    """Registry of provider factories, keyed by configuration name."""

    def __init__(self) -> None:
        self._factories: Dict[str, callable] = {}

    def register(self, name: str, factory: callable) -> None:
        self._factories[name] = factory

    def create(self, name: str, **kwargs) -> EmbeddingProvider:
        factory = self._factories.get(name)
        if factory is None:
            raise EmbeddingError(
                f"unknown embedding provider '{name}' (registered: {', '.join(sorted(self._factories)) or 'disabled'})"
            )
        return factory(**kwargs)

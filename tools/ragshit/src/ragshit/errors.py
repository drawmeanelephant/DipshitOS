"""Error hierarchy for Ragshit.

Every user-facing failure raises a subclass of :class:`RagshitError`, which
carries the process exit code the CLI should use.
"""


class RagshitError(Exception):
    """Base class for all Ragshit errors. Exit code 1 for runtime failures."""

    exit_code = 1


class UsageError(RagshitError):
    """Bad command-line usage or invalid input. Exit code 2."""

    exit_code = 2


class NotARepositoryError(RagshitError):
    """The given path is not inside a Git repository."""


class GitError(RagshitError):
    """A git command failed or reported an unexpected state."""


class ConfigError(RagshitError):
    """The .ragshit.toml configuration could not be read or is invalid."""


class DatabaseError(RagshitError):
    """The SQLite index could not be opened or is corrupt/incomplete."""


class QuerySyntaxError(UsageError):
    """A retrieval query contained an invalid filter or syntax."""


class ParseError(RagshitError):
    """A file could not be parsed for indexing."""


class BundleError(RagshitError):
    """A context bundle could not be assembled."""


class EmbeddingError(RagshitError):
    """An embedding provider was unavailable or failed."""

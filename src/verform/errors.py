"""User-facing failures with stable exit semantics."""


class VerformError(Exception):
    """Base class for expected failures."""


class ConfigError(VerformError):
    """Manifest or lock data is invalid."""


class ScaffoldError(VerformError):
    """A project cannot be scaffolded safely."""

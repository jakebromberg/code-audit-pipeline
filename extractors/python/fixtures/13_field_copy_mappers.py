"""Fixtures for the `field_copy_map` function-catalog signal.

Exercises the hand-written field-copy mapper smell (LML#610) in all three
recognized forms, plus the restraint cases the extractor must NOT flag as a
1:1 mapper:

- constructor form   — a single `return Dest(kw=src.attr, …)`
- attr-assign form   — a run of `dst.x = src.x` statements
- model_validate form — the already-fixed `Dest.model_validate(src, from_attributes=True)`
- real adapter       — mostly transforms/renames → no field_copy_map
- partial transform  — predominantly copies with one transform → emitted, transform excluded
- plain function     — no field_copy_map
"""

from __future__ import annotations

from dataclasses import dataclass

# Pydantic isn't installed in CI; only the AST base-class name matters.
from pydantic import BaseModel  # noqa: E402,F401  # type: ignore[import-not-found]


@dataclass
class Identity:
    """DB read-model — eight artist-identity fields plus the internal id."""

    id: int
    library_name: str
    discogs_artist_id: int | None = None
    wikidata_qid: str | None = None
    musicbrainz_artist_id: str | None = None
    spotify_artist_id: str | None = None
    apple_music_artist_id: str | None = None
    bandcamp_id: str | None = None
    reconciliation_status: str = "unreconciled"


class IdentityResponse(BaseModel):
    """Wire model — the same eight fields, no id."""

    library_name: str
    discogs_artist_id: int | None = None
    wikidata_qid: str | None = None
    musicbrainz_artist_id: str | None = None
    spotify_artist_id: str | None = None
    apple_music_artist_id: str | None = None
    bandcamp_id: str | None = None
    reconciliation_status: str = "unreconciled"

    @classmethod
    def from_identity(cls, identity: Identity) -> IdentityResponse:
        """model_validate form — the already-fixed, field-agnostic projection."""
        return cls.model_validate(identity, from_attributes=True)


def _identity_to_response(identity: Identity) -> IdentityResponse:
    """Constructor form (LML#610) — a run of identity keyword copies."""
    return IdentityResponse(
        library_name=identity.library_name,
        discogs_artist_id=identity.discogs_artist_id,
        wikidata_qid=identity.wikidata_qid,
        musicbrainz_artist_id=identity.musicbrainz_artist_id,
        spotify_artist_id=identity.spotify_artist_id,
        apple_music_artist_id=identity.apple_music_artist_id,
        bandcamp_id=identity.bandcamp_id,
        reconciliation_status=identity.reconciliation_status,
    )


def build_response(identity: Identity) -> IdentityResponse:
    """Constructor form via assign-then-return — the `x = Dest(...); return x` shape."""
    response = IdentityResponse(
        library_name=identity.library_name,
        discogs_artist_id=identity.discogs_artist_id,
        wikidata_qid=identity.wikidata_qid,
    )
    return response


@dataclass
class SourceRecord:
    alpha: str
    beta: str
    gamma: str
    delta: str


@dataclass
class DestRecord:
    alpha: str
    beta: str
    gamma: str
    delta: str


def copy_record(src: SourceRecord, dst: DestRecord) -> DestRecord:
    """Attr-assign form — a run of `dst.x = src.x` statements."""
    dst.alpha = src.alpha
    dst.beta = src.beta
    dst.gamma = src.gamma
    dst.delta = src.delta
    return dst


def mostly_copy_one_transform(src: SourceRecord) -> DestRecord:
    """Predominantly identity copies with one transform — emitted, but the
    transformed `delta` field is excluded from copied_fields."""
    return DestRecord(
        alpha=src.alpha,
        beta=src.beta,
        gamma=src.gamma,
        delta=src.delta.upper(),
    )


def adapter_with_transforms(identity: Identity) -> IdentityResponse:
    """Real adapter — identity copies are the minority (only `library_name`);
    the rest are renames/computed, so the extractor must NOT emit field_copy_map."""
    return IdentityResponse(
        library_name=identity.library_name,
        discogs_artist_id=int(identity.discogs_artist_id or 0),
        wikidata_qid=str(identity.wikidata_qid),
        musicbrainz_artist_id=identity.id,
        spotify_artist_id=identity.reconciliation_status.upper(),
    )


def not_a_mapper(x: int) -> int:
    """Plain function — no field_copy_map."""
    total = x + 1
    doubled = total * 2
    return doubled

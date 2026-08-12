#!/usr/bin/env python3
"""Ingest release-named media directories into the Jellyfin library on mini-pc.

Implements jellyfin/MEDIA-INGEST.md. That document is the specification; if this
script disagrees with it, this script is the bug.

Dry run is the default: nothing is written without --yes. Planning is all-or-nothing,
so a source the parser cannot name aborts the run before any byte is copied.

Usage:
    media_ingest.py [options] SOURCE_DIR [SOURCE_DIR ...]

Run with --help for the full option list.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

# ── Constants ────────────────────────────────────────────────────────────────

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".ts"}
SUBTITLE_EXTS = {".srt"}

DEFAULT_DEST = "youruser@mini-pc"
DEFAULT_LIBRARY_ROOT = "/mnt/jellyfin"
DEFAULT_JELLYFIN_URL = "http://mini-pc:8096"

# Tokens that end the title segment of a release name. Matched case-insensitively
# against the whole token and against the token with a trailing -GROUP suffix removed.
STOP_WORDS = {
    # source
    "bluray", "blu-ray", "bdrip", "brrip", "web-dl", "webdl", "webrip", "web",
    "hdrip", "dvdrip", "dvd", "remux", "hdtv", "amzn", "nf", "netflix", "hulu",
    "dsnp", "atvp", "max",
    # codec / audio
    "x264", "x265", "h264", "h265", "avc", "hevc", "xvid", "divx",
    "aac", "ac3", "eac3", "dd", "ddp", "dts", "truehd", "atmos", "flac", "opus",
    "8bit", "10bit", "hdr", "sdr", "dv",
    # structural
    "complete", "season", "extended", "remastered", "repack", "proper", "uncut",
    "unrated", "limited", "internal", "multi", "dual",
}

_RESOLUTION_RE = re.compile(r"^\d{3,4}p$", re.IGNORECASE)
_4K_RE = re.compile(r"^4k$", re.IGNORECASE)
_YEAR_RE = re.compile(r"^(19|20)\d{2}$")
_BRACKET_PREFIX_RE = re.compile(r"^\s*\[[^\]]*\]\s*")
_PAREN_YEAR_RE = re.compile(r"^(?P<title>.+?)\s*\(\s*(?P<year>(?:19|20)\d{2})\s*\)")
_SEASON_TOKEN_RE = re.compile(r"^s(\d{1,2})$", re.IGNORECASE)
_SEASON_DIR_RE = re.compile(r"^(?:season\s*|s)(\d{1,2})$", re.IGNORECASE)
# Episode tag: S01E01, S01E04E05, S01E01-E02-E03, and the dash-range form
# S05E29-32 that omits the second E. The negative lookahead on the bare-number
# alternative is load-bearing: without it a trailing `-1080p` or `-2019` reads
# as an episode number. An optional `E` would be worse still — it would make
# `Show.S01E01 1080p WEB.mkv` parse as episodes [1, 10].
_EPISODE_TAG_RE = re.compile(r"[Ss](\d{1,2})((?:[-\s]?[Ee]\d{1,2}|-\d{1,2}(?!\d))+)")
_EPISODE_NUM_RE = re.compile(r"[Ee](\d{1,2})|-(\d{1,2})(?!\d)")
# What an episode tag must NOT be followed by. `search` will happily match a
# prefix of the episode region and leave the rest on the floor, so anything
# still tag-shaped after the match means the shape is one we do not understand
# — refuse it rather than ingest a neighbour's episode number. A dash is
# deliberately absent: the tag regex already takes `-32`, so a surviving dash
# is a year or a resolution (`-2019`, `-1080p`) and is none of our business.
_TAG_CONTINUES_RE = re.compile(
    r"^(?:\d|[Ee]\d|[_+&,]\s*[Ee]?\d|\s*(?:to|thru|and)\s*[Ee]?\d)",
    re.IGNORECASE,
)
_LIBRARY_DIR_RE = re.compile(r"^(?P<title>.+?)\s*\((?P<year>(?:19|20)\d{2})\)$")
_SAMPLE_RE = re.compile(r"(^|[^a-z])sample([^a-z]|$)", re.IGNORECASE)
_ENGLISH_RE = re.compile(r"(english|\beng\b)", re.IGNORECASE)
# Accessibility and forced tracks. They are English, but they are not the track
# you want on an ordinary watch, and SDH is reliably the LARGEST file in Subs/ —
# it captions sound effects and speakers — so size alone would always pick it.
_NARROW_TRACK_RE = re.compile(r"(^|[^a-z])(sdh|hi|cc|forced)([^a-z]|$)", re.IGNORECASE)

PATH_HOSTILE = str.maketrans({"/": None, ":": None, "\0": None})


class IngestError(Exception):
    """A refusal: something could not be determined and guessing is not allowed."""


# ── Pure parsing ─────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class ReleaseName:
    """What the directory name alone can tell us."""

    title: str
    year: int | None
    is_show_hint: bool


def clean_release_name(raw: str) -> str:
    """Strip a leading bracket tag and normalize `.`/`_` separators to spaces."""
    name = _BRACKET_PREFIX_RE.sub("", raw)
    name = name.replace(".", " ").replace("_", " ")
    return re.sub(r"\s+", " ", name).strip()


def _is_stop_token(token: str) -> bool:
    lowered = token.lower()
    candidates = [lowered]
    if "-" in lowered:
        candidates.append(lowered.rsplit("-", 1)[0])
    for candidate in candidates:
        if candidate in STOP_WORDS:
            return True
        if _RESOLUTION_RE.match(candidate) or _4K_RE.match(candidate):
            return True
        if _SEASON_TOKEN_RE.match(candidate):
            return True
        if _EPISODE_TAG_RE.search(candidate):
            return True
    return False


def _has_show_marker(tokens: Sequence[str]) -> bool:
    for token in tokens:
        if _EPISODE_TAG_RE.search(token):
            return True
        if _SEASON_TOKEN_RE.match(token):
            return True
        if token.lower() == "season":
            return True
    return False


def parse_release_name(raw: str, *, allow_empty_title: bool = False) -> ReleaseName:
    """Parse a source directory basename into title / year / show-hint.

    See MEDIA-INGEST.md section 4. Raises IngestError only for an empty title;
    a missing year is reported as None and resolved by the caller.

    `allow_empty_title` is for the one caller that already holds a `--title`:
    a season directory named `S01` parses to nothing at all, and refusing it
    here would put the override out of reach of the case it exists for.
    """
    cleaned = clean_release_name(raw)
    if not cleaned:
        raise IngestError(f"empty name after cleaning: {raw!r}")

    tokens = cleaned.split(" ")
    show_hint = _has_show_marker(tokens)

    paren = _PAREN_YEAR_RE.match(cleaned)
    if paren:
        title = paren.group("title").strip()
        if not title:
            raise IngestError(f"no title before the parenthesized year in {raw!r}")
        return ReleaseName(title=title, year=int(paren.group("year")), is_show_hint=show_hint)

    stop_index = len(tokens)
    for index, token in enumerate(tokens):
        if _is_stop_token(token):
            stop_index = index
            break

    year: int | None = None
    year_index = stop_index
    for index in range(stop_index - 1, -1, -1):
        if _YEAR_RE.match(tokens[index]):
            year = int(tokens[index])
            year_index = index
            break

    title = " ".join(tokens[:year_index]).strip(" -")
    if not title and not allow_empty_title:
        raise IngestError(f"no title could be parsed from {raw!r}")
    return ReleaseName(title=title, year=year, is_show_hint=show_hint)


def normalize_title(title: str) -> str:
    """Library folder form: spaces become underscores, path-hostile chars dropped."""
    collapsed = re.sub(r"\s+", " ", title.strip())
    return collapsed.replace(" ", "_").translate(PATH_HOSTILE)


def match_key(title: str) -> str:
    """Comparison key for 'is this series already in the library'.

    Alphanumerics only, lowercased, so `Spongebob Square Pants`,
    `SpongeBob SquarePants` and `SpongeBob_SquarePants` all collapse together.
    """
    return re.sub(r"[^a-z0-9]", "", title.lower())


def parse_episode_tag(filename: str) -> tuple[int, list[int]] | None:
    """Extract (season, [episodes]) from an episode filename, or None.

    Returns None when there is no tag at all. Raises IngestError when there is
    a tag the parser can only *partly* read — see MEDIA-INGEST.md section 4.
    Half-understanding a tag is the one outcome worse than not reading it: the
    file still gets a plausible name, so the mistake survives every count and
    byte check and only surfaces as episodes Jellyfin reports as missing.
    """
    match = _EPISODE_TAG_RE.search(filename)
    if not match:
        return None
    remainder = filename[match.end():]
    if _TAG_CONTINUES_RE.match(remainder):
        raise IngestError(
            f"{filename!r}: episode tag {match.group(0)!r} is followed by "
            f"{remainder!r}, which still looks like part of the tag; this shape "
            f"is not understood and naming it would be a guess"
        )
    season = int(match.group(1))
    episodes = [int(e or bare) for e, bare in _EPISODE_NUM_RE.findall(match.group(2))]
    if not episodes:
        return None
    return season, episodes


def format_episode_tag(season: int, episodes: Sequence[int]) -> str:
    """`S01E07`, or the first-last range form `S01E01-E03` for a multi-episode file."""
    if not episodes:
        raise IngestError("cannot format an episode tag with no episode numbers")
    first, last = min(episodes), max(episodes)
    if first == last:
        return f"S{season:02d}E{first:02d}"
    return f"S{season:02d}E{first:02d}-E{last:02d}"


def folder_name(title: str, year: int) -> str:
    return f"{normalize_title(title)} ({year})"


def parse_library_dir(name: str) -> tuple[str, int] | None:
    """Split an existing library folder `Some_Title (1999)` into (title, year)."""
    match = _LIBRARY_DIR_RE.match(name)
    if not match:
        return None
    return match.group("title").replace("_", " "), int(match.group("year"))


def is_sample(path: Path) -> bool:
    return any(_SAMPLE_RE.search(part) for part in path.parts)


# ── Planning ─────────────────────────────────────────────────────────────────


@dataclass
class Transfer:
    source: Path
    dest: str
    size: int
    present: bool = False

    @property
    def action(self) -> str:
        return "skip" if self.present else "copy"


@dataclass
class SourcePlan:
    source: Path
    kind: str
    title: str
    year: int
    folder: str
    transfers: list[Transfer] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def video_files(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS and not is_sample(path)
    )


def classify(source: Path, parsed: ReleaseName) -> str:
    """movie or show, per MEDIA-INGEST.md step 3."""
    if parsed.is_show_hint:
        return "show"
    for child in source.iterdir():
        if child.is_dir() and _SEASON_DIR_RE.match(child.name):
            return "show"
    # The raw regex, not parse_episode_tag: a tag shape we only half understand
    # is still evidence this is a show. Counting it here is what routes the file
    # to the episode namer, which is where the refusal belongs — otherwise an
    # unreadable tag would quietly demote the directory to a movie and dodge it.
    tagged = sum(1 for path in video_files(source) if _EPISODE_TAG_RE.search(path.name))
    return "show" if tagged >= 2 else "movie"


def pick_subtitle(source: Path, video: Path) -> Path | None:
    """The `.srt` beside the video, else the English track under `Subs/`.

    A sibling `.srt` suppresses `Subs/` entirely. Within `Subs/`, English-named
    tracks win over the rest, ordinary tracks win over SDH/HI/CC/forced ones,
    and the largest survivor wins.
    """
    sibling = video.with_suffix(".srt")
    if sibling.is_file():
        return sibling
    subs_dir = next(
        (child for child in source.iterdir() if child.is_dir() and child.name.lower() == "subs"),
        None,
    )
    if subs_dir is None:
        return None
    candidates = [
        path
        for path in sorted(subs_dir.iterdir())
        if path.is_file() and path.suffix.lower() in SUBTITLE_EXTS
    ]
    if not candidates:
        return None
    english = [path for path in candidates if _ENGLISH_RE.search(path.name)]
    pool = english or candidates
    ordinary = [path for path in pool if not _NARROW_TRACK_RE.search(path.name)]
    pool = ordinary or pool
    if len(pool) == 1:
        return pool[0]
    # Among equally ordinary tracks, the largest is the complete one: a forced
    # or signs-only track carries a handful of lines (Iron Man's 2_English.srt
    # is 2K against 3_English.srt's 101K) and is never what you want.
    return max(pool, key=lambda path: path.stat().st_size)


def plan_source(
    source: Path,
    library: "Library",
    *,
    kind_override: str | None,
    title_override: str | None,
    year_override: int | None,
) -> SourcePlan:
    if not source.is_dir():
        raise IngestError(f"not a directory: {source}")

    parsed = parse_release_name(source.name, allow_empty_title=title_override is not None)
    title = title_override or parsed.title
    kind = kind_override or classify(source, parsed)

    existing = library.find(kind, title)
    notes: list[str] = []

    # Year resolution. For a movie the release-name year IS the film's year and is
    # trusted over an existing folder, so a remake never lands in the original's
    # folder. For a show the release-name year is the SEASON's year and is never
    # trusted; only an override or the existing series folder can supply it.
    if year_override is not None:
        year = year_override
    elif kind == "movie" and parsed.year is not None:
        year = parsed.year
    elif existing is not None:
        year = existing[1]
    elif kind == "show":
        raise IngestError(
            f"{source.name}: cannot determine the SERIES PREMIERE year for {title!r}. "
            "The year in a season pack is the season's year, not the series'. "
            "Pass --year (and --title if the library spells it differently)."
        )
    else:
        raise IngestError(
            f"{source.name}: no year could be parsed for movie {title!r}; pass --year."
        )

    if existing is not None and existing[1] == year:
        folder = existing[0]
        notes.append(f"existing library folder reused: {folder}")
    else:
        folder = folder_name(title, year)

    if kind == "show" and parsed.year is not None and parsed.year != year:
        notes.append(f"release-name year {parsed.year} is the season's; series year is {year}")

    plan = SourcePlan(source=source, kind=kind, title=title, year=year, folder=folder, notes=notes)
    root = f"{library.root}/{'shows' if kind == 'show' else 'movies'}/{folder}"

    videos = video_files(source)
    if not videos:
        raise IngestError(f"{source.name}: no video file found")

    if kind == "movie":
        video = max(videos, key=lambda path: path.stat().st_size)
        stem = folder
        plan.transfers.append(
            Transfer(video, f"{root}/{stem}{video.suffix.lower()}", video.stat().st_size)
        )
        subtitle = pick_subtitle(source, video)
        if subtitle is not None:
            plan.transfers.append(
                Transfer(subtitle, f"{root}/{stem}.srt", subtitle.stat().st_size)
            )
        if len(videos) > 1:
            notes.append(
                f"{len(videos) - 1} smaller video file(s) ignored; largest wins"
            )
    else:
        for video in videos:
            tag = parse_episode_tag(video.name)
            if tag is None:
                raise IngestError(
                    f"{source.name}: no SxxEyy tag in {video.name!r}; refusing to guess"
                )
            season, episodes = tag
            name = format_episode_tag(season, episodes) + video.suffix.lower()
            plan.transfers.append(
                Transfer(video, f"{root}/Season {season}/{name}", video.stat().st_size)
            )
            subtitle = video.with_suffix(".srt")
            if subtitle.is_file():
                plan.transfers.append(
                    Transfer(
                        subtitle,
                        f"{root}/Season {season}/{format_episode_tag(season, episodes)}.srt",
                        subtitle.stat().st_size,
                    )
                )

    return plan


def check_collisions(plans: Iterable[SourcePlan]) -> None:
    seen: dict[str, Path] = {}
    for plan in plans:
        for transfer in plan.transfers:
            previous = seen.get(transfer.dest)
            if previous is not None:
                raise IngestError(
                    f"two sources map to the same destination {transfer.dest!r}: "
                    f"{previous} and {transfer.source}"
                )
            seen[transfer.dest] = transfer.source


# ── Remote side ──────────────────────────────────────────────────────────────


class Library:
    """The remote library's existing folders, and the SSH plumbing to reach it."""

    def __init__(self, dest: str, root: str, control_path: str | None = None) -> None:
        self.dest = dest
        self.root = root.rstrip("/")
        self._control_path = control_path
        self._folders: dict[str, dict[str, tuple[str, int]]] = {"movie": {}, "show": {}}
        self._files: dict[str, int] = {}

    @property
    def ssh_options(self) -> list[str]:
        if not self._control_path:
            return []
        return [
            "-o", "ControlMaster=auto",
            "-o", f"ControlPath={self._control_path}",
            "-o", "ControlPersist=120",
        ]

    def ssh(self, command: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
        argv = ["ssh", *self.ssh_options, self.dest, command]
        return subprocess.run(argv, capture_output=True, text=True, check=check)

    def load(self) -> None:
        """One round trip: every library folder name, and every file with its size."""
        command = (
            f"ls -1 {shlex.quote(self.root)}/movies {shlex.quote(self.root)}/shows 2>/dev/null; "
            f"echo '---FILES---'; "
            f"find {shlex.quote(self.root)}/movies {shlex.quote(self.root)}/shows "
            f"-type f -printf '%s\\t%p\\n' 2>/dev/null"
        )
        result = self.ssh(command)
        section, kind = "dirs", "movie"
        for line in result.stdout.splitlines():
            if line == "---FILES---":
                section = "files"
                continue
            if section == "dirs":
                if not line.strip():
                    continue
                if line.endswith(":"):
                    kind = "show" if line.rstrip(":").endswith("/shows") else "movie"
                    continue
                parsed = parse_library_dir(line)
                if parsed:
                    title, year = parsed
                    self._folders[kind][match_key(title)] = (line, year)
            else:
                size, _, path = line.partition("\t")
                if path:
                    self._files[path] = int(size)

    def find(self, kind: str, title: str) -> tuple[str, int] | None:
        return self._folders.get(kind, {}).get(match_key(title))

    def size_of(self, path: str) -> int | None:
        return self._files.get(path)

    def mark_present(self, plans: Iterable[SourcePlan]) -> None:
        for plan in plans:
            for transfer in plan.transfers:
                transfer.present = self.size_of(transfer.dest) == transfer.size

    def mkdirs(self, directories: Iterable[str]) -> None:
        quoted = " ".join(shlex.quote(directory) for directory in sorted(set(directories)))
        if not quoted:
            return
        self.ssh(f"mkdir -p -- {quoted} && chmod 775 -- {quoted}")

    def rsync(self, transfer: Transfer) -> None:
        remote_shell = "ssh " + " ".join(shlex.quote(option) for option in self.ssh_options)
        argv = [
            "rsync",
            "-t",
            "--partial",
            "--chmod=D775,F664",
            "-e", remote_shell.strip(),
            str(transfer.source),
            f"{self.dest}:{transfer.dest}",
        ]
        subprocess.run(argv, check=True)


def trigger_scan(url: str, api_key: str) -> tuple[bool, str]:
    """POST /Library/Refresh. The key is never returned, printed, or logged."""
    request = urllib.request.Request(
        url.rstrip("/") + "/Library/Refresh",
        method="POST",
        data=b"",
        headers={
            "Authorization": f'MediaBrowser Token="{api_key}"',
            "Content-Length": "0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return True, f"HTTP {response.status}"
    except urllib.error.HTTPError as error:
        return False, f"HTTP {error.code}"
    except urllib.error.URLError as error:
        return False, f"unreachable ({error.reason})"


def read_api_key(env_file: Path) -> str | None:
    """Read JELLYFIN_API_KEY out of a KEY=VALUE env file without echoing it."""
    key = os.environ.get("JELLYFIN_API_KEY")
    if key:
        return key.strip() or None
    if not env_file.is_file():
        return None
    for line in env_file.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or "=" not in stripped:
            continue
        name, _, value = stripped.partition("=")
        if name.strip() == "JELLYFIN_API_KEY":
            return value.strip().strip("'\"") or None
    return None


# ── CLI ──────────────────────────────────────────────────────────────────────


def human(size: int) -> str:
    value = float(size)
    for unit in ("B", "K", "M", "G", "T"):
        if value < 1024 or unit == "T":
            return f"{value:.1f}{unit}" if unit != "B" else f"{int(value)}B"
        value /= 1024
    return f"{value:.1f}T"


def print_plan(plans: Sequence[SourcePlan], root: str) -> tuple[int, int]:
    to_copy = 0
    total_bytes = 0
    for plan in plans:
        print(f"\n{plan.source.name}")
        print(f"  -> {plan.kind}: {plan.folder}")
        for note in plan.notes:
            print(f"  note: {note}")
        for transfer in plan.transfers:
            relative = transfer.dest[len(root) + 1 :] if transfer.dest.startswith(root) else transfer.dest
            print(f"  [{transfer.action:4}] {human(transfer.size):>8}  {relative}")
            if not transfer.present:
                to_copy += 1
                total_bytes += transfer.size
    return to_copy, total_bytes


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="media_ingest.py",
        description="Ingest release-named media directories into the Jellyfin library.",
        epilog="Dry run is the default; pass --yes to actually copy. See MEDIA-INGEST.md.",
    )
    parser.add_argument("sources", nargs="+", metavar="SOURCE_DIR")
    parser.add_argument("-y", "--yes", action="store_true", help="execute instead of previewing")
    parser.add_argument("--kind", choices=("movie", "show"), help="override classification")
    parser.add_argument("--title", help="override the parsed title (applies to every source)")
    parser.add_argument("--year", type=int, help="override the year (applies to every source)")
    parser.add_argument("--dest", default=DEFAULT_DEST, help=f"ssh target (default {DEFAULT_DEST})")
    parser.add_argument(
        "--library-root", default=DEFAULT_LIBRARY_ROOT, help=f"default {DEFAULT_LIBRARY_ROOT}"
    )
    parser.add_argument(
        "--jellyfin-url", default=DEFAULT_JELLYFIN_URL, help=f"default {DEFAULT_JELLYFIN_URL}"
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "env" / "jellyfin.env",
        help="env file holding JELLYFIN_API_KEY",
    )
    parser.add_argument("--no-scan", action="store_true", help="do not trigger a library scan")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if (args.title or args.year or args.kind) and len(args.sources) > 1:
        print(
            "refusing: --title/--year/--kind apply to every source; pass one source at a time",
            file=sys.stderr,
        )
        return 2

    with tempfile.TemporaryDirectory(prefix="media-ingest-") as tmp:
        library = Library(args.dest, args.library_root, control_path=os.path.join(tmp, "cm"))
        try:
            library.load()
        except subprocess.CalledProcessError as error:
            print(f"cannot read the library over ssh ({args.dest}): {error.stderr.strip()}",
                  file=sys.stderr)
            return 1

        try:
            plans = [
                plan_source(
                    Path(source).expanduser().resolve(),
                    library,
                    kind_override=args.kind,
                    title_override=args.title,
                    year_override=args.year,
                )
                for source in args.sources
            ]
            check_collisions(plans)
        except IngestError as error:
            print(f"refusing: {error}", file=sys.stderr)
            return 1

        library.mark_present(plans)
        to_copy, total_bytes = print_plan(plans, library.root)
        print(f"\n{to_copy} file(s) to copy, {human(total_bytes)}")

        if not args.yes:
            print("dry run — nothing written. Re-run with --yes to execute.")
            return 0
        if to_copy == 0:
            print("nothing to do; every file is already present.")
            return 0

        pending = [t for plan in plans for t in plan.transfers if not t.present]
        library.mkdirs(os.path.dirname(transfer.dest) for transfer in pending)
        for index, transfer in enumerate(pending, start=1):
            print(f"[{index}/{len(pending)}] {transfer.dest}")
            try:
                library.rsync(transfer)
            except subprocess.CalledProcessError as error:
                print(f"rsync failed ({error.returncode}) on {transfer.source}", file=sys.stderr)
                return 1

        print(f"\ncopied {len(pending)} file(s).")

        if args.no_scan:
            return 0
        api_key = read_api_key(args.env_file)
        if not api_key:
            print(
                "no JELLYFIN_API_KEY configured — scan needed via "
                "Dashboard -> Libraries -> Scan All Libraries "
                f"(to automate, see MEDIA-INGEST.md section 6 and {args.env_file})"
            )
            return 0
        ok, detail = trigger_scan(args.jellyfin_url, api_key)
        del api_key
        if ok:
            print(f"library scan triggered ({detail}).")
        else:
            print(
                f"library scan NOT triggered ({detail}) — scan needed via "
                "Dashboard -> Libraries -> Scan All Libraries"
            )
        return 0


if __name__ == "__main__":
    sys.exit(main())

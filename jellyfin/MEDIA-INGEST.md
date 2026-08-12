# Jellyfin media ingest convention

The naming and placement rules the Jellyfin library on mini-pc actually follows,
and the release-name parsing rules needed to hit them from an arbitrary scene/WEB-DL
directory name.

Until this document existed the rules were tacit, rediscovered by hand on every ingest.
`scripts/media_ingest.py` implements exactly what is written here; if the two ever
disagree, this document is the specification and the script is the bug.

Library root on the host is `/mnt/jellyfin` (bind-mounted to `/media` inside the
container). Films go under `movies/`, series under `shows/`.

## 1. Target layout

### Movies

```
/mnt/jellyfin/movies/<Title> (<YEAR>)/<Title> (<YEAR>).<ext>
```

```
movies/Avengers_Endgame (2019)/Avengers_Endgame (2019).mkv
movies/The_Emperors_New_Groove (2000)/The_Emperors_New_Groove (2000).mp4
```

### Shows

```
/mnt/jellyfin/shows/<Title> (<SERIES_YEAR>)/Season <N>/S<xx>E<yy>.<ext>
```

```
shows/Vinland_Saga (2019)/Season 1/S01E01.mkv
shows/SpongeBob_SquarePants (1999)/Season 1/S01E04-E05.mkv
```

- Season folder is `Season N`, **not** zero-padded (`Season 1`, not `Season 01`).
- Episode filenames are stripped to the bare tag. No episode titles, no release group.
- Season and episode numbers in the filename **are** zero-padded to two digits.
- Multi-episode files use the first-last range form: `S01E04-E05.mkv`. A triple
  (`S01E01E02E03` at the source) collapses to `S01E01-E03.mkv`, matching what is
  already on disk in `SpongeBob_SquarePants (1999)/Season 1`.

### `<Title>` normalization

Spaces become underscores; everything else in the parsed title is preserved, including
apostrophes and internal hyphens (`But_I'm_A_Cheerleader (1999)`, `Spider-Man_Homecoming (2017)`).
Path-hostile characters (`/`, `:`, NUL) are dropped.

The existing library is **mixed**: most folders use underscores, a minority use spaces
(`Ghost in the Shell (1995)`, `The Orville (2017)`, `La La Land (2016)`). Jellyfin matches
on title + year, not on separator style, so both work. Rule: **normalize new entries to
the underscore form, never rewrite existing folders.** Rewriting is churn that buys
nothing and risks orphaning watch state.

### The series-year rule (load-bearing)

The year in a show folder is the **series premiere year**, not the year of the season
being ingested. This is not cosmetic: it is how Jellyfin identifies the series, so
getting it wrong creates a second, duplicate series entry.

Release names cannot supply it. `Vinland Saga S02 2023 ... -DBTV` carries **2023**, while
the correct library folder is `Vinland_Saga (2019)`. Therefore the show year is resolved
in this order, and never guessed from the release name:

1. an explicit `--year` on the command line;
2. an existing library folder whose normalized title matches (its year wins, so
   second-season ingests land in the folder that already exists);
3. otherwise **refuse to proceed** and say so.

Movies are the opposite case: the year in the release name *is* the film's year, and is
used directly.

## 2. Sidecar policy

| Sidecar | Action | Why |
|---|---|---|
| `.srt` beside the video | **Copy**, renamed to the target stem | Subtitles are content; the library already carries them (`Dune_Part_Two (2024).srt`) |
| `Subs/*English*.srt` | **Copy** one English track, renamed to the target stem | The common scene layout (`Subs/10_English.srt`). Non-English tracks are not ingested; add them by hand if wanted |
| `.nfo` | **Drop** | Stale scraper metadata from an unrelated library. Jellyfin fetches its own and prefers it |
| `.jpg` / `.png` artwork | **Drop** | Same reason. The handful of `.jpg` files in the library predate this convention |
| `sample*` files, `Sample/` dirs | **Drop** | Not content |
| Anything else | **Drop** | Ingest is allow-list, not deny-list |

### Which subtitle, exactly

Exactly one `.srt` is ingested per video. The two table rows above are a **precedence
order**, not two independent rules: an `.srt` beside the video wins outright and `Subs/`
is not read at all. Sources that ship both — `Backrooms (2026)` ships a top-level
`Backrooms….srt` *and* a `Subs/` directory — take the sibling.

Inside `Subs/`, the pick narrows in three steps:

1. **English only.** Names matching `english` or a standalone `eng` (case-insensitive).
   If nothing matches, every `.srt` in the directory stays in the running rather than
   ingesting no subtitle at all.
2. **Ordinary tracks over narrow ones.** A name carrying `sdh`, `hi`, `cc`, or `forced`
   as a standalone token is set aside. SDH captions sound effects and speakers, so it is
   reliably the *largest* file in `Subs/` — without this step the size tie-break below
   would pick the accessibility track every time one exists, and `[door creaks]` would
   show up on an ordinary watch. If the narrow tracks are all there is, the largest of
   them is ingested; an SDH track beats no subtitle.
3. **Largest wins.** Among equally ordinary tracks, size separates the complete track
   from a signs-only one. `Iron.Man.2008.PROPER.REMASTERED` ships `Subs/2_English.srt`
   (2K, signs only) beside `Subs/3_English.srt` (101K, the real thing), and neither name
   says which is which.

Wanting a different track is a manual copy; this tool does not offer a selector.

## 3. Ownership and permissions

Files land as `youruser:youruser`, mode **664**; directories **775**. That is what the
container (running as uid 1000) needs to read them, and it is what the recent entries on
disk already carry (`Avengers_Endgame (2019)`).

Ownership comes for free because the transfer runs as `youruser` over SSH; modes are set
explicitly by rsync (`--chmod=D775,F664`) rather than inherited from the source, whose
umask is a different machine's business.

Legacy entries with 644/755 (`Dune_Part_Two (2024)`, `Ghost in the Shell (1995)`) are
readable and are left alone. Do not sweep the library to normalize modes.

## 4. Parse rules

Applied to the **basename of the source directory**.

**Step 0 — clean.** Strip a leading bracket tag (`[Req] `, `[GroupName] `). Replace `.`
and `_` with spaces and collapse runs of whitespace. This is lossy for titles containing
a real period (`Batman vs. Teenage…` parses as `vs`), which only ever affects the title
segment and is accepted; pass `--title` to override.

**Step 1 — parenthesized year.** If the name contains `(YYYY)`, that is an already-clean
name: title is everything before the paren, year is the paren contents, the rest is
discarded. This handles hand-named sources like `Spider-Man Homecoming (2017) -jlw`.

**Step 2 — stop-token scan.** Otherwise, find the index of the first *stop token*, which
is any of:

- resolution: `480p 576p 720p 1080p 2160p 4K`
- source: `BluRay BDRip BRRip WEB-DL WEBRip WEBDL HDRip DVDRip REMUX HDTV AMZN NF`
- codec/audio: `x264 x265 H264 H265 AVC HEVC AAC AC3 DD DDP DTS TrueHD 10bit`
- structural: `Complete Season S<dd> S<dd>E<dd> Extended Remastered Repack Proper`

The **title** is the tokens before the last year-shaped token (`19xx`/`20xx`) that
precedes the stop token; the **year** is that token. Taking the *last* such year rather
than the first is what keeps `2001 A Space Odyssey 1968 1080p BluRay` from parsing as
year 2001.

If no stop token is found, the whole name is the title and there is no year.

**Step 3 — classify.** The source is a **show** if any of these hold, else a **movie**:

- the directory name carries `S<dd>E<dd>`, a standalone `S<dd>`, or `Season <n>`;
- it contains subdirectories named `S<dd>` or `Season <n>`;
- two or more video files under it carry an `S<dd>E<dd>` tag.

**Step 4 — episodes.** For each video file in a show, match
`S(\d{1,2})((?:[-\s]?E\d{1,2}|-\d{1,2}(?!\d))+)` on the filename. The season number in
the *episode tag* is authoritative and outranks the season directory name. All episode
numbers in the tag are collected; the output tag is `S{ss}E{ee}` for one,
`S{ss}E{first}-E{last}` for more.

Two multi-episode forms are understood. The **repeated-E** form gives every episode its
own `E` (`S01E04E05`, `S01E01-E02-E03`). The **dash-range** form omits the second `E`
and writes only the endpoints (`S05E29-32`, the four-part Steven Universe finale); it
normalizes to the same output as the repeated form, `S05E29-E32.mkv`. A bare number
after a dash counts as an episode *only* when no further digit follows it, which is what
keeps a trailing `-1080p` or `-2019` from being read as an episode number.

**Step 5 — movie file.** The largest video file in the tree, excluding samples.
`.mkv .mp4 .avi .m4v .mov .ts` count as video.

### Fail loudly

Every one of these **refuses the whole run** rather than guessing, because a
misfiled item is worse than a failed one — Jellyfin will happily create a duplicate
series or a wrongly-dated film and then need manual repair:

- no year could be parsed for a movie, and no `--year` given;
- no series year resolved for a show (no `--year`, no matching library folder);
- an empty title after parsing, and no `--title` given — a source directory named for
  nothing but its season (`S01`, as in the Steven Universe complete collection) parses to
  no title at all, and `--title` is what rescues it;
- a show file with no parseable `S<dd>E<dd>` tag;
- a show file whose tag is only **partly** readable — the match ended but what follows
  still looks like part of the tag (`S01E01to03`, `S01E01_02`, `S01E01+02`, `S01E011`).
  This is the worst failure the tool can have, so it is the loudest: a half-read tag
  still produces a plausible filename, so the file lands with a neighbour's episode
  number, the bytes and the file count both check out, and the only visible symptom is
  Jellyfin reporting episodes as missing whose content is already in the library. The
  refusal names the file and the unread remainder. Widening the tag regex to cover a new
  shape is how a shape becomes *supported*; until then it must refuse rather than guess;
- no video file found in a source directory;
- two source files that map to the same destination path.

The run aborts during planning, before a single byte is copied. Partial ingests are not
a supported state.

### Parse table

Real names from `~/media-temp` on the workstation, and what they produce.

| Source directory | Shape | Parsed | Destination |
|---|---|---|---|
| `Vinland Saga S01 2019 Complete 1080p Netflix WEB-DL AVC AAC 2 0-DBTV` | Netflix WEB-DL, DBTV, space-separated | kind=show · title=`Vinland Saga` · the `S01` token stops the title scan **before** the 2019, so no year is parsed at all; series year 2019 comes from the existing folder | `shows/Vinland_Saga (2019)/Season 1/S01E01.mkv` … `S01E24.mkv` |
| `Vinland Saga S02 2023 Complete 1080p Netflix WEB-DL AVC AAC 2 0-DBTV` | same, second season | same: the 2023 is never reached, and would be **discarded** if it were (e.g. `Vinland.Saga.2023.S02.…`, where the year precedes the season token) | `shows/Vinland_Saga (2019)/Season 2/S02E01.mkv` … |
| `Avengers.Endgame.2019.1080p.BluRay.DDP5.1.x265.10bit-LAMA` | BluRay x265 LAMA, dot-separated | kind=movie · title=`Avengers Endgame` · year=2019 | `movies/Avengers_Endgame (2019)/Avengers_Endgame (2019).mkv` |
| `Glorious.2022.1080p.AMZN.WEB-DL.DDP2.0.H.264-EVO` | WEB-DL EVO | kind=movie · title=`Glorious` · year=2022 | `movies/Glorious (2022)/Glorious (2022).mkv` |
| `Spider-Man Homecoming (2017) -jlw` | already-clean, parenthesized | kind=movie · title=`Spider-Man Homecoming` · year=2017 | `movies/Spider-Man_Homecoming (2017)/Spider-Man_Homecoming (2017).mkv` |
| `The.Emperors.New.Groove.2000.1080p.BluRay.x265-LAMA` | BluRay x265 with `Subs/` | kind=movie · title=`The Emperors New Groove` · year=2000 · `Subs/10_English.srt` picked up | `movies/The_Emperors_New_Groove (2000)/The_Emperors_New_Groove (2000).mp4` + `.srt` |
| `Shrek.2.2004.1080p.BluRay.x265-LAMA` | sequel number butting against the year | kind=movie · the stop token is `1080p`, the last year-shaped token before it is `2004`, so the sequel `2` stays in the title | `movies/Shrek_2 (2004)/Shrek_2 (2004).mp4` |
| `Iron.Man.2.2010.PROPER.REMASTERED.1080p.BluRay.x265-LAMA` | stop token that is not a resolution | kind=movie · `PROPER` stops the scan four tokens before `1080p` is reached; year=2010, title=`Iron Man 2` | `movies/Iron_Man_2 (2010)/Iron_Man_2 (2010).mp4` |
| `Backrooms (2026) 1080p WEBRip 5.1-LAMA` | parenthesized year, sibling `.srt` **and** a `Subs/` dir | kind=movie · title=`Backrooms` · year=2026 · the sibling `.srt` wins and `Subs/` (English, SDH, Spanish, Arabic) is never read | `movies/Backrooms (2026)/Backrooms (2026).mp4` + `.srt` |
| `[Req] Spongebob Square Pants Season 1-15` | multi-season pack, bracket tag, no year | kind=show · title=`Spongebob Square Pants` · no year in the name; resolved **only** because `SpongeBob_SquarePants (1999)` already exists and the match key ignores spelling | `shows/SpongeBob_SquarePants (1999)/Season 1/S01E01-E03.mkv` … |

The SpongeBob row is the point of both the match-key rule and the fail-loud rule. The
pack carries no year and spells the title differently from the series (`Square Pants` vs
`SquarePants`); the alphanumeric-only match key collapses that difference, so on **this**
library the existing folder resolves it. On a library that did not already have the
series, it is refused, and needs `--title "SpongeBob SquarePants" --year 1999`. Either
way the episode tags inside (`S01E01-E02-E03`, `S01E04E05`) collapse to the range form.

### Episode-tag table

| Source filename | Parsed | Output |
|---|---|---|
| `Vinland.Saga.S01E07.2019.1080p.Netflix.WEB-DL.AVC.AAC.2.0-DBTV.mkv` | s=1, e=[7] | `S01E07.mkv` |
| `SpongeBob SquarePants S01E04E05 Bubblestand - Ripped Pants.mkv` | s=1, e=[4,5] | `S01E04-E05.mkv` |
| `SpongeBob SquarePants S01E01-E02-E03 Help Wanted - Reef Blower-Tea The Threedome.mkv` | s=1, e=[1,2,3] | `S01E01-E03.mkv` |
| `Some.Show.S02E11.1080p.WEB.mkv` inside `Season 1/` | s=2 (tag wins), e=[11] | `Season 2/S02E11.mkv` |
| `S05E29-32.mp4` | s=5, e=[29,32] — dash-range endpoints | `S05E29-E32.mp4` |
| `Show.S01E01-1080p.WEB.mkv` | s=1, e=[1] — `-1080` is not an episode | `S01E01.mkv` |

## 5. Walkthrough

Run from a workstation that can reach the server over SSH as `youruser` (the transfer is a
push; nothing needs to be installed on the server). Python 3 stdlib only, no dependencies.

**Step 1 — preview.** Dry run is the default. Nothing is written, and the plan shows every
file with its destination and whether it is already present.

```console
$ jellyfin/scripts/media_ingest.py ~/media-temp/Glorious.2022.1080p.AMZN.WEB-DL.DDP2.0.H.264-EVO

Glorious.2022.1080p.AMZN.WEB-DL.DDP2.0.H.264-EVO
  -> movie: Glorious (2022)
  note: existing library folder reused: Glorious (2022)
  [skip]     3.3G  movies/Glorious (2022)/Glorious (2022).mkv

0 file(s) to copy, 0B
dry run — nothing written. Re-run with --yes to execute.
```

**Step 2 — read the plan.** Check the folder line (`-> movie: …` / `-> show: …`), the
notes, and the destination paths. `[skip]` means the file is already there at the same
size, so a re-run after an interrupted transfer costs nothing.

**Step 3 — execute.** Add `--yes`. On success the tool triggers a library scan (section 6).

```bash
jellyfin/scripts/media_ingest.py --yes ~/media-temp/Only.God.Forgives.2013.1080p.BluRay.H264.AAC
```

Background anything larger than a few gigabytes; a full season pack runs well past a
10-minute foreground timeout.

```bash
nohup jellyfin/scripts/media_ingest.py --yes ~/media-temp/Some.Show.S01.* > /tmp/ingest.log 2>&1 &
tail -f /tmp/ingest.log
```

**Step 4 — when it refuses.** A refusal names the source and what it could not determine.
Supply it and re-run; overrides apply to every source in the invocation, so pass one
source at a time when using them.

```console
$ jellyfin/scripts/media_ingest.py "~/media-temp/[Req] Spongebob Square Pants Season 1-15"
refusing: … cannot determine the SERIES PREMIERE year for 'Spongebob Square Pants'. …

$ jellyfin/scripts/media_ingest.py --yes --title "SpongeBob SquarePants" --year 1999 \
      "~/media-temp/[Req] Spongebob Square Pants Season 1-15"
```

Other options: `--kind movie|show` to override classification, `--dest` /
`--library-root` to target a different host or library, `--no-scan` to skip the scan
trigger. `--help` lists them all.

Transfers are `rsync` over a shared SSH connection and preserve nothing from the source
but content and mtime; ownership and modes come from section 3.

## 6. Library scan

A successful ingest posts `/Library/Refresh` to Jellyfin so the new media appears without
a Dashboard click. Authentication is a dedicated Jellyfin API key read from
`jellyfin/env/jellyfin.env` (gitignored, chmod 600, see `jellyfin.env.example`).

The key is read directly into the request and is never printed, logged, or echoed. With
no key configured the ingest still completes and prints the manual fallback instruction
instead of failing.

To create the key: Jellyfin Dashboard → API Keys → **+**, name it `media-ingest`, and
write it into `jellyfin/env/jellyfin.env`. A named key can be revoked on its own, which
a reused user session token cannot; that is why the tool will not accept one.

## 7. Packaging decision

**Decision: a standalone documented tool in this repo, not a forged recipe.**

The alternative was registering the capability as a `mini-pc-jellyfin-media-ingest`
recipe in the toolkit DB, following the `mini-pc-*` family, invoked through
`admin.apply_recipe`. That path is closed: `admin.apply_recipe` is a **deferred stub** in
the Go toolkit-server (confirmed via `admin.action_describe` on 2026-08-03) and returns a
deferred envelope rather than executing anything. The already-forged `mini-pc-*` recipes
are equally un-runnable today. Registering a recipe would have produced a row that looks
like a capability and does nothing.

What was chosen instead is the standard homelab surface as it actually exists: a script
under the stack directory it belongs to, a specification and walkthrough beside it, a
gitignored `env/` for its secret, and coverage in `ci/validate.sh` and the Gitea CI
workflow — the same shape as `restic/scripts/backup.sh` and `monitoring/scripts/`.

**Follow-up:** suggestion `port-apply-recipe-out-of-deferred-stub` (project
corpos-toolkit) tracks porting the recipe walker. When it lands, this capability is the
obvious first candidate to re-package, and section 5 becomes the recipe's step list. The
tool is written to make that cheap: parsing is pure and separately tested, and every
side-effecting step already runs behind a dry-run preview and an idempotency check.

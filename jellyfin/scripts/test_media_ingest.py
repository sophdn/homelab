#!/usr/bin/env python3
"""Regression net for media_ingest.py.

Everything here is sans-IO: the parsing functions are pure, and the planner is
exercised against a fake library plus a temporary source tree. No SSH, no rsync,
no network. Run with `python3 -m unittest discover jellyfin/scripts` or via
`ci/validate.sh`.

The parse cases are the real release names from ~/media-temp, kept in step with
the parse table in MEDIA-INGEST.md section 4.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import media_ingest as mi


class FakeLibrary:
    """Stands in for Library: the folders that already exist, nothing more."""

    def __init__(self, root: str = "/mnt/jellyfin", folders: dict | None = None) -> None:
        self.root = root
        self._folders = folders or {"movie": {}, "show": {}}

    def find(self, kind: str, title: str):
        return self._folders.get(kind, {}).get(mi.match_key(title))


def make_tree(base: Path, name: str, files: list[str]) -> Path:
    source = base / name
    for relative in files:
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * 1024)
    source.mkdir(parents=True, exist_ok=True)
    return source


class CleanNameTest(unittest.TestCase):
    def test_strips_leading_bracket_tag(self):
        self.assertEqual(
            mi.clean_release_name("[Req] Spongebob Square Pants Season 1-15"),
            "Spongebob Square Pants Season 1-15",
        )

    def test_dots_and_underscores_become_spaces(self):
        self.assertEqual(
            mi.clean_release_name("Avengers.Endgame.2019.1080p"),
            "Avengers Endgame 2019 1080p",
        )
        self.assertEqual(mi.clean_release_name("Some_Movie_2001"), "Some Movie 2001")

    def test_empty_after_cleaning_is_empty(self):
        self.assertEqual(mi.clean_release_name("[group]"), "")


class ParseReleaseNameTest(unittest.TestCase):
    def assert_parse(self, raw, title, year, is_show):
        parsed = mi.parse_release_name(raw)
        self.assertEqual(parsed.title, title, raw)
        self.assertEqual(parsed.year, year, raw)
        self.assertEqual(parsed.is_show_hint, is_show, raw)

    def test_netflix_web_dl_season_pack(self):
        self.assert_parse(
            "Vinland Saga S01 2019 Complete 1080p Netflix WEB-DL AVC AAC 2 0-DBTV",
            "Vinland Saga",
            None,
            True,
        )

    def test_second_season_pack_year_is_not_the_series_year(self):
        # The name carries 2023; the parser must not offer it as the series year.
        self.assert_parse(
            "Vinland Saga S02 2023 Complete 1080p Netflix WEB-DL AVC AAC 2 0-DBTV",
            "Vinland Saga",
            None,
            True,
        )

    def test_bluray_x265_lama(self):
        self.assert_parse(
            "Avengers.Endgame.2019.1080p.BluRay.DDP5.1.x265.10bit-LAMA",
            "Avengers Endgame",
            2019,
            False,
        )

    def test_web_dl_evo(self):
        self.assert_parse(
            "Glorious.2022.1080p.AMZN.WEB-DL.DDP2.0.H.264-EVO", "Glorious", 2022, False
        )

    def test_already_clean_parenthesized_form(self):
        self.assert_parse(
            "Spider-Man Homecoming (2017) -jlw", "Spider-Man Homecoming", 2017, False
        )

    def test_subs_bearing_bluray_release(self):
        self.assert_parse(
            "The.Emperors.New.Groove.2000.1080p.BluRay.x265-LAMA",
            "The Emperors New Groove",
            2000,
            False,
        )

    def test_multi_season_pack_has_no_year(self):
        self.assert_parse(
            "[Req] Spongebob Square Pants Season 1-15",
            "Spongebob Square Pants",
            None,
            True,
        )

    def test_title_starting_with_a_year_takes_the_last_year(self):
        self.assert_parse(
            "2001.A.Space.Odyssey.1968.1080p.BluRay.x265", "2001 A Space Odyssey", 1968, False
        )

    def test_hyphenated_title_survives(self):
        self.assert_parse(
            "Spider-Man No Way Home.2022.1080p.BDRip.X264.AC3-EVO",
            "Spider-Man No Way Home",
            2022,
            False,
        )

    def test_no_title_is_refused(self):
        with self.assertRaises(mi.IngestError):
            mi.parse_release_name("[group]")
        with self.assertRaises(mi.IngestError):
            mi.parse_release_name("1080p.BluRay.x265")

    def test_an_incoming_title_override_suspends_the_refusal(self):
        parsed = mi.parse_release_name("S01", allow_empty_title=True)
        self.assertEqual(parsed.title, "")
        self.assertTrue(parsed.is_show_hint)


class TitleNormalizationTest(unittest.TestCase):
    def test_spaces_become_underscores(self):
        self.assertEqual(mi.normalize_title("Avengers Endgame"), "Avengers_Endgame")

    def test_apostrophes_and_hyphens_are_kept(self):
        self.assertEqual(mi.normalize_title("But I'm A Cheerleader"), "But_I'm_A_Cheerleader")
        self.assertEqual(mi.normalize_title("Spider-Man Homecoming"), "Spider-Man_Homecoming")

    def test_path_hostile_characters_are_dropped(self):
        self.assertEqual(mi.normalize_title("2001: A Space Odyssey"), "2001_A_Space_Odyssey")
        self.assertEqual(mi.normalize_title("AC/DC Live"), "ACDC_Live")

    def test_match_key_collapses_spelling_and_separators(self):
        self.assertEqual(
            mi.match_key("Spongebob Square Pants"), mi.match_key("SpongeBob_SquarePants")
        )
        self.assertEqual(mi.match_key("Ghost in the Shell"), mi.match_key("Ghost_In_The_Shell"))
        self.assertNotEqual(mi.match_key("Predator"), mi.match_key("Predator Badlands"))

    def test_folder_name(self):
        self.assertEqual(mi.folder_name("Vinland Saga", 2019), "Vinland_Saga (2019)")


class LibraryDirTest(unittest.TestCase):
    def test_parses_underscore_form(self):
        self.assertEqual(mi.parse_library_dir("Vinland_Saga (2019)"), ("Vinland Saga", 2019))

    def test_parses_space_form(self):
        self.assertEqual(
            mi.parse_library_dir("Ghost in the Shell (1995)"), ("Ghost in the Shell", 1995)
        )

    def test_rejects_a_folder_with_no_year(self):
        self.assertIsNone(mi.parse_library_dir("lost+found"))


class EpisodeTagTest(unittest.TestCase):
    def test_single_episode(self):
        self.assertEqual(
            mi.parse_episode_tag("Vinland.Saga.S01E07.2019.1080p.Netflix.WEB-DL.mkv"), (1, [7])
        )

    def test_paired_episode(self):
        self.assertEqual(
            mi.parse_episode_tag("SpongeBob SquarePants S01E04E05 Bubblestand.mkv"), (1, [4, 5])
        )

    def test_triple_episode_with_dashes(self):
        self.assertEqual(
            mi.parse_episode_tag("SpongeBob SquarePants S01E01-E02-E03 Help Wanted.mkv"),
            (1, [1, 2, 3]),
        )

    def test_dash_range_without_a_second_e(self):
        # The four-part Steven Universe finale ships as S05E29-32; before the
        # range form was understood this parsed as episode 29 alone and the
        # other three looked missing in Jellyfin.
        self.assertEqual(mi.parse_episode_tag("S05E29-32.mp4"), (5, [29, 32]))

    def test_a_trailing_resolution_is_not_an_episode(self):
        # The reason the dash alternative carries a negative lookahead: a bare
        # number after a dash is only an episode if no more digits follow it.
        self.assertEqual(mi.parse_episode_tag("Show.S01E01 1080p WEB.mkv"), (1, [1]))
        self.assertEqual(mi.parse_episode_tag("Show.S01E01-1080p.WEB.mkv"), (1, [1]))

    def test_a_trailing_year_is_not_an_episode(self):
        self.assertEqual(mi.parse_episode_tag("Show.S01E01-2019.1080p.mkv"), (1, [1]))

    def test_a_trailing_group_tag_is_not_an_episode(self):
        self.assertEqual(mi.parse_episode_tag("Show.S01E01-GROUP.mkv"), (1, [1]))

    def test_untagged_file(self):
        self.assertIsNone(mi.parse_episode_tag("Some Movie (2019).mkv"))


class PartiallyParsedTagTest(unittest.TestCase):
    """A tag shape the parser only partly understands must be loud, not truncated.

    Widening the regex covers the shapes we know about; this covers the ones we
    do not. A silent mislabel is worse than a refusal because the bytes are
    right and only the name is wrong, which no count or size check will catch.
    """

    def assert_refused(self, filename: str, remainder: str):
        with self.assertRaises(mi.IngestError) as caught:
            mi.parse_episode_tag(filename)
        message = str(caught.exception)
        self.assertIn(filename, message)
        self.assertIn(remainder, message)

    def test_worded_range_is_refused(self):
        self.assert_refused("Show.S01E01to03.mkv", "to03")

    def test_underscore_separated_pair_is_refused(self):
        self.assert_refused("Show.S01E01_02.mkv", "_02")

    def test_plus_separated_pair_is_refused(self):
        self.assert_refused("Show.S01E01+02.mkv", "+02")

    def test_ampersand_separated_pair_is_refused(self):
        self.assert_refused("Show.S01E01&02.mkv", "&02")

    def test_a_three_digit_episode_number_is_refused(self):
        # E011 might mean episode 11 zero-padded three wide, or episode 1
        # followed by something else. The tool does not know, so it must say so
        # rather than quietly ingesting it as episode 1.
        self.assert_refused("Show.S01E011.mkv", "1")

    def test_shapes_the_tool_understands_are_untouched(self):
        for filename in (
            "Vinland.Saga.S01E07.2019.1080p.Netflix.WEB-DL.mkv",
            "SpongeBob SquarePants S01E04E05 Bubblestand.mkv",
            "SpongeBob SquarePants S01E01-E02-E03 Help Wanted.mkv",
            "S05E29-32.mp4",
            "Show.S01E01 1080p WEB.mkv",
            "Show.S01E01-1080p.WEB.mkv",
            "Show.S01E01-2019.1080p.mkv",
            "Show.S01E01-GROUP.mkv",
            "Show.S01E01.Toy.Story.mkv",
            "Show.S01E01 tonight.mkv",
        ):
            with self.subTest(filename=filename):
                self.assertIsNotNone(mi.parse_episode_tag(filename))

    def test_format_single(self):
        self.assertEqual(mi.format_episode_tag(1, [7]), "S01E07")

    def test_format_range_uses_first_and_last(self):
        self.assertEqual(mi.format_episode_tag(1, [4, 5]), "S01E04-E05")
        self.assertEqual(mi.format_episode_tag(1, [1, 2, 3]), "S01E01-E03")

    def test_format_pads_two_digits(self):
        self.assertEqual(mi.format_episode_tag(12, [3]), "S12E03")


class SampleTest(unittest.TestCase):
    def test_sample_files_are_recognized(self):
        self.assertTrue(mi.is_sample(Path("/x/Sample/thing.mkv")))
        self.assertTrue(mi.is_sample(Path("/x/movie-sample.mkv")))

    def test_ordinary_names_are_not(self):
        self.assertFalse(mi.is_sample(Path("/x/Samples_of_Life (2019).mkv")))


class PlanMovieTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def plan(self, source, library=None, **overrides):
        options = {"kind_override": None, "title_override": None, "year_override": None}
        options.update(overrides)
        return mi.plan_source(source, library or FakeLibrary(), **options)

    def test_movie_lands_at_the_convention_path(self):
        source = make_tree(
            self.base,
            "Glorious.2022.1080p.AMZN.WEB-DL.DDP2.0.H.264-EVO",
            ["Glorious.2022.1080p.AMZN.WEB-DL.mkv"],
        )
        plan = self.plan(source)
        self.assertEqual(plan.kind, "movie")
        self.assertEqual(plan.folder, "Glorious (2022)")
        self.assertEqual(
            [t.dest for t in plan.transfers],
            ["/mnt/jellyfin/movies/Glorious (2022)/Glorious (2022).mkv"],
        )

    def test_largest_video_wins_and_nfo_is_dropped(self):
        source = make_tree(
            self.base,
            "The.Ritual.2017.1080p.BluRay.x265",
            ["The.Ritual.2017.mp4", "The.Ritual.2017.mp4.nfo", "The.Ritual.2017.jpg"],
        )
        (source / "The.Ritual.2017.mp4").write_bytes(b"x" * 4096)
        plan = self.plan(source)
        self.assertEqual(
            [t.dest for t in plan.transfers],
            ["/mnt/jellyfin/movies/The_Ritual (2017)/The_Ritual (2017).mp4"],
        )

    def test_english_subtitle_under_subs_is_picked_up(self):
        source = make_tree(
            self.base,
            "The.Emperors.New.Groove.2000.1080p.BluRay.x265-LAMA",
            [
                "The.Emperors.New.Groove.2000.mp4",
                "Subs/10_English.srt",
                "Subs/3_French.srt",
            ],
        )
        plan = self.plan(source)
        self.assertEqual(
            [t.dest for t in plan.transfers],
            [
                "/mnt/jellyfin/movies/The_Emperors_New_Groove (2000)/"
                "The_Emperors_New_Groove (2000).mp4",
                "/mnt/jellyfin/movies/The_Emperors_New_Groove (2000)/"
                "The_Emperors_New_Groove (2000).srt",
            ],
        )

    def test_sibling_subtitle_beats_the_subs_directory(self):
        source = make_tree(
            self.base,
            "Movie.Name.2019.1080p.BluRay.x265",
            ["Movie.Name.2019.mkv", "Movie.Name.2019.srt", "Subs/2_English.srt"],
        )
        plan = self.plan(source)
        self.assertEqual(plan.transfers[1].source.name, "Movie.Name.2019.srt")

    def test_the_sdh_track_loses_to_the_plain_english_one(self):
        # The Backrooms (2026) layout, minus the sibling .srt that masks it.
        source = make_tree(
            self.base,
            "Backrooms.2026.1080p.WEBRip.x264-LAMA",
            [
                "Backrooms.2026.1080p.WEBRip.x264-LAMA.mp4",
                "Subs/English.srt",
                "Subs/SDH.eng.HI.srt",
                "Subs/Latin American.spa.srt",
            ],
        )
        (source / "Subs/English.srt").write_bytes(b"x" * 74481)
        (source / "Subs/SDH.eng.HI.srt").write_bytes(b"x" * 128038)
        plan = self.plan(source)
        self.assertEqual(plan.transfers[1].source.name, "English.srt")

    def test_an_sdh_track_alone_is_still_better_than_no_subtitle(self):
        source = make_tree(
            self.base,
            "Movie.Name.2019.1080p.BluRay.x265",
            ["Movie.Name.2019.mkv", "Subs/SDH.eng.HI.srt"],
        )
        plan = self.plan(source)
        self.assertEqual(plan.transfers[1].source.name, "SDH.eng.HI.srt")

    def test_the_forced_track_loses_to_the_full_one_on_size(self):
        # Iron.Man.2008.PROPER.REMASTERED: neither name says "forced", so the
        # only thing separating the signs-only track from the real one is size.
        source = make_tree(
            self.base,
            "Iron.Man.2008.PROPER.REMASTERED.1080p.BluRay.x265-LAMA",
            [
                "Iron.Man.2008.PROPER.REMASTERED.mp4",
                "Subs/2_English.srt",
                "Subs/3_English.srt",
            ],
        )
        (source / "Subs/2_English.srt").write_bytes(b"x" * 2071)
        (source / "Subs/3_English.srt").write_bytes(b"x" * 103445)
        plan = self.plan(source)
        self.assertEqual(plan.transfers[1].source.name, "3_English.srt")

    def test_ordinary_titles_are_not_mistaken_for_narrow_tracks(self):
        source = make_tree(
            self.base,
            "Movie.Name.2019.1080p.BluRay.x265",
            ["Movie.Name.2019.mkv", "Subs/2_English.srt", "Subs/Hindi.srt"],
        )
        (source / "Subs/2_English.srt").write_bytes(b"x" * 4096)
        plan = self.plan(source)
        self.assertEqual(plan.transfers[1].source.name, "2_English.srt")

    def test_existing_folder_with_the_same_year_is_reused_verbatim(self):
        library = FakeLibrary(
            folders={"movie": {mi.match_key("Ghost in the Shell"): ("Ghost in the Shell (1995)", 1995)},
                     "show": {}}
        )
        source = make_tree(
            self.base, "Ghost.in.the.Shell.1995.1080p.BluRay.x265", ["gits.mkv"]
        )
        plan = self.plan(source, library)
        self.assertEqual(plan.folder, "Ghost in the Shell (1995)")

    def test_a_remake_does_not_land_in_the_originals_folder(self):
        library = FakeLibrary(
            folders={"movie": {mi.match_key("The Thing"): ("The_Thing (1982)", 1982)}, "show": {}}
        )
        source = make_tree(self.base, "The.Thing.2011.1080p.BluRay.x265", ["thing.mkv"])
        plan = self.plan(source, library)
        self.assertEqual(plan.folder, "The_Thing (2011)")

    def test_a_movie_with_no_year_is_refused(self):
        source = make_tree(self.base, "Some Unnamed Rip", ["a.mkv"])
        with self.assertRaises(mi.IngestError):
            self.plan(source)

    def test_year_override_rescues_it(self):
        source = make_tree(self.base, "Some Unnamed Rip", ["a.mkv"])
        plan = self.plan(source, year_override=1999)
        self.assertEqual(plan.folder, "Some_Unnamed_Rip (1999)")

    def test_a_source_with_no_video_is_refused(self):
        source = make_tree(self.base, "Glorious.2022.1080p.WEB-DL", ["readme.nfo"])
        with self.assertRaises(mi.IngestError):
            self.plan(source)


class PlanShowTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def plan(self, source, library=None, **overrides):
        options = {"kind_override": None, "title_override": None, "year_override": None}
        options.update(overrides)
        return mi.plan_source(source, library or FakeLibrary(), **options)

    def vinland_library(self):
        return FakeLibrary(
            folders={
                "movie": {},
                "show": {mi.match_key("Vinland Saga"): ("Vinland_Saga (2019)", 2019)},
            }
        )

    def test_a_bare_season_directory_is_rescued_by_the_overrides(self):
        # The Steven Universe complete-collection layout: the pack cannot be
        # ingested whole, so each season directory is passed on its own and
        # carries no title of its own to parse.
        source = make_tree(self.base, "S01", ["S01E01.mp4", "S01E02.mp4"])
        plan = self.plan(source, title_override="Steven Universe", year_override=2013)
        self.assertEqual(plan.kind, "show")
        self.assertEqual(plan.folder, "Steven_Universe (2013)")
        self.assertEqual(
            [t.dest for t in plan.transfers],
            [
                "/mnt/jellyfin/shows/Steven_Universe (2013)/Season 1/S01E01.mp4",
                "/mnt/jellyfin/shows/Steven_Universe (2013)/Season 1/S01E02.mp4",
            ],
        )

    def test_a_bare_season_directory_without_a_title_is_still_refused(self):
        source = make_tree(self.base, "S01", ["S01E01.mp4", "S01E02.mp4"])
        with self.assertRaises(mi.IngestError):
            self.plan(source, year_override=2013)

    def test_season_two_lands_under_the_series_premiere_year(self):
        source = make_tree(
            self.base,
            "Vinland Saga S02 2023 Complete 1080p Netflix WEB-DL AVC AAC 2 0-DBTV",
            [
                "Vinland.Saga.S02E01.2023.1080p.Netflix.WEB-DL.mkv",
                "Vinland.Saga.S02E02.2023.1080p.Netflix.WEB-DL.mkv",
                "pack.nfo",
            ],
        )
        plan = self.plan(source, self.vinland_library())
        self.assertEqual(plan.kind, "show")
        self.assertEqual(plan.folder, "Vinland_Saga (2019)")
        self.assertEqual(
            [t.dest for t in plan.transfers],
            [
                "/mnt/jellyfin/shows/Vinland_Saga (2019)/Season 2/S02E01.mkv",
                "/mnt/jellyfin/shows/Vinland_Saga (2019)/Season 2/S02E02.mkv",
            ],
        )
        self.assertTrue(any("existing library folder reused" in note for note in plan.notes))

    def test_a_year_bearing_show_name_is_overridden_by_the_series_folder(self):
        # This shape DOES surface a year to the parser (it precedes the S02 token),
        # and the series folder must still win.
        source = make_tree(
            self.base,
            "Vinland.Saga.2023.S02.1080p.WEB-DL.x265",
            ["Vinland.Saga.S02E01.mkv", "Vinland.Saga.S02E02.mkv"],
        )
        self.assertEqual(mi.parse_release_name(source.name).year, 2023)
        plan = self.plan(source, self.vinland_library())
        self.assertEqual(plan.folder, "Vinland_Saga (2019)")
        self.assertTrue(any("season's" in note for note in plan.notes))

    def test_a_show_with_no_year_and_no_library_match_is_refused(self):
        source = make_tree(
            self.base,
            "Brand New Show S01 2024 Complete 1080p WEB-DL",
            ["Brand.New.Show.S01E01.mkv", "Brand.New.Show.S01E02.mkv"],
        )
        with self.assertRaises(mi.IngestError) as caught:
            self.plan(source)
        self.assertIn("SERIES PREMIERE", str(caught.exception))

    def test_overrides_rescue_a_multi_season_pack(self):
        source = make_tree(
            self.base,
            "[Req] Spongebob Square Pants Season 1-15",
            [
                "S01/SpongeBob SquarePants S01E01-E02-E03 Help Wanted.mkv",
                "S01/SpongeBob SquarePants S01E04E05 Bubblestand.mkv",
                "S02/SpongeBob SquarePants S02E01E02 Something.mkv",
            ],
        )
        plan = self.plan(
            source, title_override="SpongeBob SquarePants", year_override=1999
        )
        self.assertEqual(plan.folder, "SpongeBob_SquarePants (1999)")
        self.assertEqual(
            [t.dest for t in plan.transfers],
            [
                "/mnt/jellyfin/shows/SpongeBob_SquarePants (1999)/Season 1/S01E01-E03.mkv",
                "/mnt/jellyfin/shows/SpongeBob_SquarePants (1999)/Season 1/S01E04-E05.mkv",
                "/mnt/jellyfin/shows/SpongeBob_SquarePants (1999)/Season 2/S02E01-E02.mkv",
            ],
        )

    def test_the_episode_tag_outranks_the_season_directory(self):
        source = make_tree(
            self.base,
            "Some Show S01 2020 Complete 1080p WEB-DL",
            ["Season 1/Some.Show.S02E11.1080p.WEB.mkv", "Season 1/Some.Show.S02E12.mkv"],
        )
        plan = self.plan(source, year_override=2020)
        self.assertEqual(
            [t.dest for t in plan.transfers],
            [
                "/mnt/jellyfin/shows/Some_Show (2020)/Season 2/S02E11.mkv",
                "/mnt/jellyfin/shows/Some_Show (2020)/Season 2/S02E12.mkv",
            ],
        )

    def test_an_untagged_episode_file_is_refused(self):
        source = make_tree(
            self.base,
            "Vinland Saga S01 2019 Complete 1080p Netflix WEB-DL",
            ["Vinland.Saga.S01E01.mkv", "extras/behind the scenes.mkv"],
        )
        with self.assertRaises(mi.IngestError) as caught:
            self.plan(source, self.vinland_library())
        self.assertIn("refusing to guess", str(caught.exception))

    def test_a_partially_parsed_tag_aborts_planning(self):
        # Not a parser unit test: this proves the refusal reaches the same
        # all-or-nothing planning gate as every other fail-loud condition, so
        # no bytes move for any file in the run.
        source = make_tree(
            self.base,
            "Vinland Saga S01 2019 Complete 1080p Netflix WEB-DL",
            ["Vinland.Saga.S01E01.mkv", "Vinland.Saga.S01E02to04.mkv"],
        )
        with self.assertRaises(mi.IngestError) as caught:
            self.plan(source, self.vinland_library())
        message = str(caught.exception)
        self.assertIn("Vinland.Saga.S01E02to04.mkv", message)
        self.assertIn("to04", message)

    def test_a_partially_parsed_tag_still_classifies_as_a_show(self):
        # The unrecognized shape must not demote the directory to a movie and
        # thereby dodge the refusal — it is episode-tag-ish, so it counts for
        # classification and then refuses at naming time.
        source = make_tree(
            self.base,
            "Some Show 2020 1080p WEB-DL",
            ["Some.Show.S01E01to03.mkv", "Some.Show.S01E04to06.mkv"],
        )
        with self.assertRaises(mi.IngestError) as caught:
            self.plan(source, year_override=2020)
        self.assertIn("to03", str(caught.exception))

    def test_untagged_directory_with_season_subdirs_classifies_as_show(self):
        source = make_tree(
            self.base,
            "Some Show 2020 1080p WEB-DL",
            ["Season 1/Some.Show.S01E01.mkv"],
        )
        plan = self.plan(source, year_override=2020)
        self.assertEqual(plan.kind, "show")

    def test_episode_subtitles_follow_their_episode(self):
        source = make_tree(
            self.base,
            "Vinland Saga S01 2019 Complete 1080p Netflix WEB-DL",
            ["Vinland.Saga.S01E01.mkv", "Vinland.Saga.S01E01.srt"],
        )
        plan = self.plan(source, self.vinland_library())
        self.assertEqual(
            [t.dest for t in plan.transfers],
            [
                "/mnt/jellyfin/shows/Vinland_Saga (2019)/Season 1/S01E01.mkv",
                "/mnt/jellyfin/shows/Vinland_Saga (2019)/Season 1/S01E01.srt",
            ],
        )


class CollisionTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_two_sources_mapping_to_one_destination_are_refused(self):
        library = FakeLibrary()
        first = make_tree(self.base, "Glorious.2022.1080p.WEB-DL", ["a.mkv"])
        second = make_tree(self.base, "Glorious.2022.1080p.BluRay.x265", ["b.mkv"])
        plans = [
            mi.plan_source(
                path, library, kind_override=None, title_override=None, year_override=None
            )
            for path in (first, second)
        ]
        with self.assertRaises(mi.IngestError):
            mi.check_collisions(plans)


class ApiKeyTest(unittest.TestCase):
    def test_reads_the_key_from_an_env_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / "jellyfin.env"
            env.write_text(
                "# comment\nJELLYFIN_URL=http://x:8096\nJELLYFIN_API_KEY='abc123'\n",
                encoding="utf-8",
            )
            self.assertEqual(mi.read_api_key(env), "abc123")

    def test_missing_file_is_not_an_error(self):
        self.assertIsNone(mi.read_api_key(Path("/nonexistent/jellyfin.env")))

    def test_missing_key_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / "jellyfin.env"
            env.write_text("JELLYFIN_URL=http://x:8096\n", encoding="utf-8")
            self.assertIsNone(mi.read_api_key(env))


if __name__ == "__main__":
    unittest.main()

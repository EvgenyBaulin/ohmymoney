#!/usr/bin/env python3
"""Writes a String Catalog (.xcstrings) from a JSON mapping read on stdin.

String Catalogs are JSON; writing them from a script keeps the two languages side by side
and lets a script add strings without opening Xcode.

Each value of the mapping is either a pair `[en, ru]` or, for a string with a number in it,
the plural forms of each language:

    {"selection.count": {"en": {"one": "%lld operation", "other": "%lld operations"},
                         "ru": {"one": "%lld операция", "few": "%lld операции",
                                "many": "%lld операций", "other": "%lld операции"}}}

Usage:

    make_xcstrings.py Catalog.xcstrings < strings.json          # writes the whole catalog
    make_xcstrings.py --merge Catalog.xcstrings < strings.json  # adds or updates these keys
    make_xcstrings.py --self-test                               # checks the merge (check-scripts)

Without `--merge` the catalog is replaced by exactly the keys given — never run it that way
on an existing catalog with a partial mapping, it would drop every other key. With
`--merge` the keys already in the catalog stay as they are, the given ones are added or get
new English and Russian texts (what else Xcode keeps in an entry, such as a comment, stays),
and a catalog that does not exist yet is created.
"""
import json
import os
import sys

LANGUAGES = ("en", "ru")
# The plural categories each language needs (CLDR): Russian tells one, few and many apart.
PLURALS = {"en": ("one", "other"), "ru": ("one", "few", "many", "other")}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(language, value):
    if isinstance(value, str):
        return unit(value)
    missing = [form for form in PLURALS[language] if not value.get(form)]
    if missing:
        raise ValueError(f"{language}: plural forms missing: {', '.join(missing)}")
    return {"variations": {"plural": {form: unit(text) for form, text in value.items()}}}


def entry(key, value):
    if isinstance(value, dict):
        values = value
    else:
        en, ru = value
        values = {"en": en, "ru": ru}
    for language in LANGUAGES:
        if not values.get(language):
            raise ValueError(f"{key}: no {language} text")
    return {
        "extractionState": "manual",
        "localizations": {
            language: localization(language, values[language]) for language in LANGUAGES
        },
    }


def merged(old, new):
    """The entry `new` over the one already in the catalog: its English and Russian replace
    theirs, and whatever else Xcode keeps there — a comment for translators, `shouldTranslate`,
    another language, the extraction state of a key found in code or its absence — stays."""
    result = dict(old)
    localizations = dict(old.get("localizations", {}))
    localizations.update(new["localizations"])
    result["localizations"] = localizations
    return result


def build(entries, existing=None):
    catalog = existing or {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    for key, value in entries.items():
        new = entry(key, value)
        old = catalog["strings"].get(key)
        catalog["strings"][key] = merged(old, new) if old else new
    return catalog


def write(path, catalog):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def self_test():
    """A merge replaces the English and Russian texts of a key and keeps everything else."""
    existing = {
        "sourceLanguage": "en",
        "version": "1.0",
        "strings": {
            "kept": entry("kept", ["Kept", "Оставлен"]),
            "extracted": {"localizations": {"en": unit("Found"), "ru": unit("Найден")}},
            "updated": {
                "comment": "A note for translators, written in Xcode.",
                "extractionState": "extracted_with_value",
                "localizations": {
                    "de": unit("Alt"),
                    "en": unit("Old"),
                    "ru": unit("Старый"),
                },
            },
        },
    }
    before_kept = json.loads(json.dumps(existing["strings"]["kept"]))
    catalog = build(
        {
            "updated": ["New", "Новый"],
            "added": ["Added", "Добавлен"],
            "extracted": ["Found in code", "Найден в коде"],
        },
        existing,
    )
    strings = catalog["strings"]
    updated = strings["updated"]
    problems = []
    if updated.get("comment") != "A note for translators, written in Xcode.":
        problems.append("the comment of an updated key was dropped")
    if updated.get("extractionState") != "extracted_with_value":
        problems.append("the extraction state of an updated key was replaced")
    if updated["localizations"].get("de") != unit("Alt"):
        problems.append("a third language of an updated key was dropped")
    if updated["localizations"].get("en") != unit("New"):
        problems.append("the English text was not updated")
    if updated["localizations"].get("ru") != unit("Новый"):
        problems.append("the Russian text was not updated")
    if "extractionState" in strings["extracted"]:
        problems.append("a key Xcode found in code was made manual")
    if strings["extracted"]["localizations"].get("en") != unit("Found in code"):
        problems.append("the English text of a key found in code was not updated")
    if strings.get("kept") != before_kept:
        problems.append("a key not given was changed")
    if strings.get("added") != entry("added", ["Added", "Добавлен"]):
        problems.append("a new key was not written as a new entry")
    if problems:
        sys.exit("make_xcstrings self-test: " + "; ".join(problems))
    print("make_xcstrings self-test: ok")


def main(arguments):
    if arguments == ["--self-test"]:
        self_test()
        return
    merge = "--merge" in arguments
    paths = [argument for argument in arguments if argument != "--merge"]
    if len(paths) != 1:
        sys.exit(__doc__)
    path = paths[0]
    entries = json.load(sys.stdin)
    existing = None
    if merge and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            existing = json.load(handle)
    write(path, build(entries, existing))


if __name__ == "__main__":
    main(sys.argv[1:])

#!/usr/bin/env python3
"""Generate Bean's versioned, synthetic writing corpus without network access.

Seeds are manually annotated examples, expanded through fixed writing contexts.
They are not independent human judgments or representative provider responses.
Split assignment is by seed family, never by a random row of the same sentence.
"""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Tests" / "Fixtures" / "WritingQuality"
VERSION = 1

# Correct controls include multiple English conventions, informal fragments,
# names, protected technical spans, and text outside the English scope.
CLEAN = [
    "Thanks! See you soon.", "Can we meet tomorrow?", "I have already sent the report.",
    "The team is ready for the release.", "We are reviewing the final document.",
    "I had had enough by then.", "She said that that approach works.", "No, no, that is fine.",
    "We need to go to the office.", "I cannot approve the change yet.",
    "We might deliver it on Friday.", "Please do not change the deadline.",
    "I'll check it after lunch.", "That's fine — no worries!", "sounds good 👍",
    "Thanks for the heads-up.", "All good here.", "Quick update: the deployment is complete.",
    "The colour of the centre sign is grey.", "The color of the center sign is gray.",
    "Our neighbour reviewed the catalogue.", "Our neighbor reviewed the catalog.",
    "The organisation has a licence for this programme.",
    "The organization has a license for this program.", "We will organise the meeting.",
    "We will organize the meeting.", "Anees and Anvika are meeting Quorvio tomorrow.",
    "Will Smith reviewed the report with Taylor Nguyen.", "RetailNext uses PostgreSQL and Kubernetes.",
    "Use HTTP and OAuth for this endpoint.", "Read https://teh.example.com/recieve?item=12.",
    "Email teh@example.com before the meeting.", "The file is /tmp/teh/recieve.swift.",
    "Use teh_file, tehFile, and teh2 as identifiers.", "Mention @teh and #recieve in the test.",
    "`teh  code` stays literal.", "```swift\nlet teh = \"recieve\"\n```",
    "| teh | adress |\n| --- | --- |", "It costs 1.50; the total is 12.00.",
    "Read teh.md and ask J.Smith about it.", "  Indentation and trailing spaces stay.  ",
    "First line.\r\nSecond line.\u2028Third line.\u2029Last line.",
    "👩🏽‍💻 The café is open. The cafe\u0301 is busy.", "你好，明天见。", "Merci pour votre aide.",
    "Nos vemos mañana.", "Please keep the phrase teh Company exactly.",
    "I can help, but I cannot promise a date.", "I have no objections to this plan.",
    "The quote says: “Do not change my words.”"
]

# No typo is manufactured from the application's dictionary at generation time.
# These independent seeds deliberately include errors beyond the local rules.
SPELLING = [
    "Please send [[teh=>the]] report.", "We will [[recieve=>receive]] the package.",
    "I [[recieved=>received]] the confirmation.", "That is [[definately=>definitely]] correct.",
    "Keep the two items [[seperate=>separate]].", "The error [[occured=>occurred]] yesterday.",
    "Please update the [[adress=>address]].", "We will meet [[tomorow=>tomorrow]].",
    "This is a [[wierd=>weird]] result.", "I left [[becuase=>because]] it was late.",
    "They brought [[thier=>their]] notes.", "We can [[accomodate=>accommodate]] the request.",
    "Please check the [[grammer=>grammar]].", "The [[enviroment=>environment]] is ready.",
    "The launch was [[sucessful=>successful]].", "I [[beleive=>believe]] it is ready.",
    "There is a [[misspeling=>misspelling]] in this sentence.",
    "I am [[writting=>writing]] a message.", "We need better [[comunication=>communication]].",
    "This is a useful [[oppurtunity=>opportunity]].", "The plan is [[availble=>available]] now.",
    "Please confirm the [[schedul=>schedule]].", "We value your [[feedbak=>feedback]].",
    "The team will [[resovle=>resolve]] the issue.", "Please check the [[attachement=>attachment]].",
    "I have a [[quesiton=>question]] about this.", "We need a clear [[descripton=>description]].",
    "This [[mesage=>message]] is ready.", "The [[documment=>document]] is complete.",
    "I will [[folow=>follow]] up soon.", "Please [[revview=>review]] the draft.",
    "The [[meetting=>meeting]] starts soon.", "This is an [[importent=>important]] update.",
    "The result looks [[promissing=>promising]].", "We have [[enought=>enough]] time.",
    "Please [[consdier=>consider]] the proposal.", "That is a [[diffrent=>different]] issue.",
    "The [[develpment=>development]] work is complete.", "We appreciate your [[patence=>patience]].",
    "We need [[adittional=>additional]] information."
]

GRAMMAR = [
    "I [[has=>have]] a question.", "He [[are=>is]] ready.", "She [[are=>is]] reviewing it.",
    "It [[are=>is]] available now.", "They [[is=>are]] on their way.", "We [[is=>are]] ready.",
    "You [[is=>are]] welcome to join.", "I [[is=>am]] waiting for the update.",
    "She [[have=>has]] the latest version.", "He [[have=>has]] the notes.",
    "It [[have=>has]] a clear explanation.", "They [[has=>have]] a meeting today.",
    "We [[has=>have]] enough information.", "You [[has=>have]] the correct file.",
    "Please read [[the the=>the]] document.", "Send the report [[to to=>to]] the team.",
    "We are ready [[and and=>and]] waiting.", "This is [[a apple=>an apple]].",
    "I need [[an useful=>a useful]] explanation.", "The results [[was=>were]] clear.",
    "There [[is=>are]] three options.", "The team [[work=>works]] together.",
    "Yesterday, I [[go=>went]] to the office.", "We have [[finish=>finished]] the report."
]

SURFACE = [
    ("punctuation", "Hello[[,=>, ]]friend!"),
    ("punctuation", "Thanks[[!=>! ]]Next, we will review it."),
    ("punctuation", "The draft is ready[[.=>. ]]Please review it."),
    ("punctuation", "Please check this[[;=>; ]]then send it."),
    ("spacing", "Please[[  => ]]review the draft."),
    ("spacing", "We need[[   => ]]more time."),
    ("spacing", "  Please[[  => ]]review the draft.  "),
    ("spacing", "First line.\r\nWe[[  => ]]are ready.\u2028Next line."),
    ("capitalization", "[[i=>I]] think the update is ready."),
    ("capitalization", "[[i=>I]]’m ready to help."),
    ("capitalization", "[[i=>I]] will send it soon."),
    ("capitalization", "[[i=>I]] have the latest version."),
    ("capitalization", "[[i=>I]] need more time."),
    ("capitalization", "[[i=>I]] believe this will work.")
]

CONTEXTS = [
    ("chat", "", "", "en_CA"),
    ("email", "Hello Morgan,\n\n", "\n\nThanks,\nJamie", "en_US"),
    ("prose", "Today's update: ", " The next review is on Friday.", "en_GB"),
    ("chat", "👩🏽‍💻 ", " 👍", "en_CA"),
    ("email", "", "\n\nPlease retain https://docs.example.org/v1 and ref_12.", "en_US"),
    ("prose", "Notes:\n- ", "\n- The deadline is unchanged.", "en_GB"),
    ("chat", "Update for Quorvio: ", "", "en_CA"),
    ("email", "First note: ", "\nQuoted test: `teh  token`.", "en_US")
]

def utf16_length(text):
    return len(text.encode("utf-16-le")) // 2

def expand(marked, error_type):
    text, expected, issues, cursor = "", "", [], 0
    for match in re.finditer(r"\[\[(.*?)=>(.*?)\]\]", marked, flags=re.S):
        plain = marked[cursor:match.start()]
        text += plain
        expected += plain
        original, correction = match.groups()
        issues.append({"location": utf16_length(text), "length": utf16_length(original),
                       "original": original, "corrections": [correction], "type": error_type})
        text += original
        expected += correction
        cursor = match.end()
    text += marked[cursor:]
    expected += marked[cursor:]
    return text, expected, issues

def main():
    families = [("clean", x) for x in CLEAN] + [("spelling", x) for x in SPELLING]
    families += [("grammar", x) for x in GRAMMAR] + SURFACE
    rows = []
    for index, (kind, seed) in enumerate(families):
        family = f"v{VERSION}-{kind}-{index:03d}"
        # Every fifth family is reserved. Context variants cannot cross splits.
        split = "heldout" if index % 5 == 4 else "development"
        plain, corrected, annotations = expand(seed, kind)
        for context_index, (domain, prefix, suffix, dialect) in enumerate(CONTEXTS):
            # Indentation and Markdown hard breaks must remain at line edges;
            # wrapping them inline would manufacture unlabeled spacing errors.
            if plain.startswith((" ", "\t")) and prefix and not prefix.endswith("\n"):
                prefix = prefix.rstrip(" ") + "\n"
            if plain.endswith((" ", "\t")) and suffix and not suffix.startswith("\n"):
                suffix = "\n" + suffix.lstrip(" ")
            if plain in ("你好，明天见。", "Merci pour votre aide.", "Nos vemos mañana."):
                prefix, suffix, dialect = "", "", "automatic"
                # Retain distinct case identity; language controls are not eight
                # independent linguistic examples. The manifest discloses this.
            issues = [dict(issue, location=issue["location"] + utf16_length(prefix))
                      for issue in annotations]
            dictionary = ["Quorvio", "teh Company", "ref_12", "RetailNext", "PostgreSQL", "OAuth"]
            # A separate repeated/Unicode probe tests occurrence identity with
            # exact independently annotated offsets, rather than fuzzy matching.
            if context_index == 7 and kind == "spelling":
                prefix, suffix = "👩🏽‍💻 ", " " + plain
                issues = [dict(issue, location=issue["location"] + utf16_length(prefix))
                          for issue in annotations]
                issues += [dict(issue, location=issue["location"] + utf16_length(prefix + plain + " "))
                           for issue in annotations]
                expected = prefix + corrected + " " + corrected
            else:
                expected = prefix + corrected + suffix
            rows.append({"id": f"{family}-{context_index}", "family": family, "split": split,
                         "domain": domain, "dialect": dialect, "text": prefix + plain + suffix,
                         "expectedText": expected, "dictionary": dictionary, "issues": issues})
    DESTINATION.mkdir(parents=True, exist_ok=True)
    encoded = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows)
    corpus = DESTINATION / "corpus-v1.jsonl"
    corpus.write_text(encoded, encoding="utf-8")
    manifest = {
        "version": VERSION, "cases": len(rows), "families": len(families),
        "sha256": hashlib.sha256(encoded.encode()).hexdigest(),
        "splits": {name: sum(row["split"] == name for row in rows) for name in ("development", "heldout")},
        "cleanCases": sum(not row["issues"] for row in rows),
        "provenance": "Manually annotated synthetic seeds with fixed generated context variants; no personal writing or provider responses.",
        "reviewStatus": "Agent-curated; requires independent human language review and external corpus evaluation.",
        "limitations": ["Context variants are correlated, not independent examples.",
                        "Heldout families share some error patterns; this is a regression holdout, not proof of generalization.",
                        "Three short non-English controls recur without context variations.",
                        "Dialect alternatives in clean controls are intentionally valid, not mandatory style changes.",
                        "Provider mapping replay scores measure exact mapping only, never real model quality."]
    }
    (DESTINATION / "manifest-v1.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"cases": len(rows), "families": len(families), "sha256": manifest["sha256"]}))

if __name__ == "__main__":
    main()

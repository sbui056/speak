"""Recognition accuracy: target-word hits and word error rate.

Usage:
  accuracy.py <expected> <got>       score a dictation run line by line
  accuracy.py --lab <sentences> <tsv> score recognizer-lab output
  accuracy.py --self-test

Expected file: one sentence per line, optionally numbered ("4. ..."). Lines
starting with # are ignored; "## Name" starts a section, and WER is reported
per section. Target phrases are marked [[pull request]]; a line starting with
CONTROL: is a control sentence whose marked words must not get worse.
Got file: what Speak typed, one line per expected line, in order (# ignored).
Lab TSV: voice, rate, sentence number (1-based), text.
"""
import re
import sys
from collections import Counter, namedtuple
from difflib import SequenceMatcher

FILLERS = {"um", "uh", "er", "erm", "hmm"}
# Spelled both ways in normal writing; compared joined.
COMPOUNDS = ["backoff", "timeout", "login", "logout", "setup", "signup", "checkout",
             "standup", "workflow", "codebase", "filename", "username", "database",
             "frontend", "backend", "onboarding", "healthcheck"]
SAME = {"ok": "okay"}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n):
    if n < 20:
        return ONES[n]
    if n == 100:
        return "one hundred"
    return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])


def words(text):
    """Lowercase words of letters, digits and apostrophes (the rule Corpus.swift
    uses), fillers dropped, numbers 0-100 as words, known compounds joined."""
    text = text.lower().replace("\u2019", "'")
    out = []
    for w in re.findall(r"[\w']+", text):
        w = w.strip("'").replace("_", "")
        if not w or w in FILLERS:
            continue
        if w.isdigit() and int(w) <= 100:
            out.extend(number_words(int(w)).split())
        else:
            out.append(SAME.get(w, w))
    joined = " ".join(out)
    for c in COMPOUNDS:
        for split in range(1, len(c)):
            joined = re.sub(rf"\b{c[:split]} {c[split:]}\b", c, joined)
    return joined.split()


def normalize(text):
    return " ".join(words(text))


Line = namedtuple("Line", "section text targets control")


def parse_expected(text):
    lines, section = [], ""
    for raw in text.splitlines():
        raw = raw.strip()
        if raw.startswith("## "):
            section = raw[3:].strip()
        if not raw or raw.startswith("#"):
            continue
        raw = re.sub(r"^\d+\.\s*", "", raw)
        control = raw.startswith("CONTROL:")
        if control:
            raw = raw[len("CONTROL:"):].strip()
        targets = re.findall(r"\[\[(.+?)\]\]", raw)
        lines.append(Line(section, re.sub(r"\[\[(.+?)\]\]", r"\1", raw), targets, control))
    return lines


def target_hit(target, got):
    return f" {normalize(target)} " in f" {normalize(got)} "


def wer_counts(expected, got):
    """(word edits, expected word count)."""
    a, b = words(expected), words(got)
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[:], i
        for j in range(1, len(b) + 1):
            d[j] = min(prev[j] + 1, d[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1]))
    return d[-1], len(a)


def swaps(expected, got):
    a, b = words(expected), words(got)
    out = []
    for op, i1, i2, j1, j2 in SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op != "equal":
            out.append(f"{' '.join(a[i1:i2]) or '-'} → {' '.join(b[j1:j2]) or '-'}")
    return out


def report(pairs):
    """pairs: [(label, Line, got text)]. Prints per-line results and the summary."""
    hits = total = controls_wrong = 0
    edits, counts, missed = Counter(), Counter(), Counter()
    for label, line, got in pairs:
        ok = [t for t in line.targets if target_hit(t, got)]
        lost = [t for t in line.targets if t not in ok]
        if line.control:
            controls_wrong += len(lost)
        else:
            hits, total = hits + len(ok), total + len(line.targets)
        missed.update(lost)
        e, n = wer_counts(line.text, got)
        edits[line.section] += e
        counts[line.section] += n
        sw = swaps(line.text, got)
        if line.targets or sw:
            kind = "control " if line.control else ""
            print(f"{label}	{kind}{len(ok)}/{len(line.targets)}	{'; '.join(sw)}")
    if missed:
        print("missed: " + ", ".join(f"{t}×{n}" for t, n in missed.most_common()))
    sections = " ".join(f"{s or 'all'}={100 * edits[s] / counts[s]:.1f}%" for s in counts if counts[s])
    all_wer = 100 * sum(edits.values()) / max(1, sum(counts.values()))
    print(f"targets={hits}/{total} controls_wrong={controls_wrong} wer={all_wer:.1f}%" + (f" ({sections})" if len(counts) > 1 else ""))


def main(args):
    if args[:1] == ["--lab"]:
        lines = parse_expected(open(args[1]).read())
        pairs = []
        for row in open(args[2]):
            voice, rate, index, *text = row.rstrip("\n").split("\t")
            pairs.append((f"{index} {voice} {rate}", lines[int(index) - 1], text[0] if text else ""))
        report(pairs)
        return
    lines = parse_expected(open(args[0]).read())
    got = [l.strip() for l in open(args[1]).read().splitlines() if l.strip() and not l.startswith("#")]
    if len(got) != len(lines):
        print(f"warning: {len(lines)} expected lines, {len(got)} got lines; pairing by order", file=sys.stderr)
    report([(str(i + 1), line, g) for i, (line, g) in enumerate(zip(lines, got))])


def self_test():
    assert normalize("Um, I paid $2 for it.") == "i paid two for it"
    assert normalize("backoff") == normalize("back off")
    assert normalize("OK") == normalize("okay")
    assert normalize("It’s six") == normalize("it's 6")
    assert normalize("off-by-one") == "off by one"
    assert target_hit("pull request", "Did you see the pull request?")
    assert not target_hit("pull request", "Did you see the pool request?")
    assert not target_hit("main", "the fix will remain")
    assert target_hit("CI", "CI should be green")
    assert wer_counts("Sounds good, see you then.", "Sounds good. See you then.") == (0, 5)
    assert wer_counts("push to main", "push to man") == (1, 3)
    lines = parse_expected("# note\n## Literal\n21. I pushed the fix to [[main]].\nCONTROL: I paid in [[cash]].\n")
    assert [(l.section, l.text, l.targets, l.control) for l in lines] == [
        ("Literal", "I pushed the fix to main.", ["main"], False),
        ("Literal", "I paid in cash.", ["cash"], True),
    ]
    print("self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3 or (len(sys.argv) == 4 and sys.argv[1] == "--lab"):
        main(sys.argv[1:])
    else:
        sys.exit(__doc__)

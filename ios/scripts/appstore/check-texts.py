"""Prüft die Zeichengrenzen der Texte in docs/APPSTORE.md, wie App Store Connect sie zählt.

    python3 -I ios/scripts/appstore/check-texts.py docs/APPSTORE.md
"""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "docs/APPSTORE.md"
text = open(path, encoding="utf-8").read()
bad = False


def report(name, value, limit):
    global bad
    n = len(value)
    flag = "ok" if n <= limit else "ZU LANG"
    bad |= n > limit
    print(f"{flag:8} {name}: {n}/{limit}")


# Tabellenzeilen wie "| Untertitel (30) | Bläserhefte und EG durchsuchen |"
for name, limit, value in re.findall(r"^\| ([^|(]+?) \((\d+)\) \| (.+?) \|$", text, re.M):
    report(name, value, int(limit))

# Abschnitte wie "### Werbetext (170)" bis zur nächsten Überschrift
for name, limit, body in re.findall(r"^### (.+?) \((\d+)\)\n\n(.*?)(?=\n#{2,3} |\Z)", text, re.M | re.S):
    report(name, body.strip(), int(limit))

keywords = re.search(r"^### Keywords \(\d+\)\n\n(.+)$", text, re.M)
if keywords and re.search(r", | ,", keywords.group(1)):
    print("HINWEIS  Keywords: Leerzeichen um Kommas zählen mit, besser weglassen")

sys.exit(1 if bad else 0)

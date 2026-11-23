#!/usr/bin/env python3
"""Read the metadata of an rpm-md repository and compare two states of it (run as `python3 -I`).

    repo-state.py revision <repomd.xml>
    repo-state.py primary <repomd.xml>                     the href of the primary file
    repo-state.py packages <repomd.xml> <primary.xml.gz>   name, arch, epoch, version, release, sha256, location
    repo-state.py vercmp <a> <b>                           -1, 0 or 1, as rpm says it
    repo-state.py locations <repomd.xml>                   every file the index lists: href and sha256
    repo-state.py order <served-repomd> <served-primary> <next-repomd> <next-primary> [<retired-file>]

`order` is the rule that keeps a repository from going backwards: the next state must have a
revision greater than the served one, must still carry every package name and architecture the
served one carries (unless the retired file names it), none of them may be older than the served
one, and a package that is the same version must be the same file (same sha256), since a version
that was published is never published again with other bytes.

Versions are compared by rpm itself (`rpm --eval '%{lua: print(rpm.vercmp(...))}'`, epoch aside, which is a number):
a comparison written here would differ from the consumer's on the cases nobody thought of (a leading zero, `~`, `^`),
and the verdict on whether a repository goes backwards is the consumer's. There is no copy of rpmvercmp in this file.

Everything read here comes from a repository we published, and is still read as untrusted: the
files are size bounded, the primary file must match the checksum repomd.xml gives it, and an
href outside `repodata/` is refused.
"""
import gzip
import io
import hashlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

REPO_NS = "{http://linux.duke.edu/metadata/repo}"
COMMON_NS = "{http://linux.duke.edu/metadata/common}"
MAX_XML_BYTES = 64 * 1024 * 1024
MAX_PRIMARY_BYTES = 512 * 1024 * 1024
PRIMARY_HREF = re.compile(r"^repodata/[0-9a-f]{64}-primary\.xml\.gz$")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")


class Refusal(Exception):
    pass


def read_bounded(path, limit):
    with open(path, "rb") as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise Refusal(f"{path} is over {limit} bytes")
    return data


def parse_repomd(path):
    root = ET.fromstring(read_bounded(path, MAX_XML_BYTES))
    revision = root.findtext(f"{REPO_NS}revision")
    if revision is None or not re.fullmatch(r"[0-9]{9,11}", revision):
        raise Refusal(f"{path} has no revision made of 9 to 11 ASCII digits")
    primary = None
    for data in root.findall(f"{REPO_NS}data"):
        if data.get("type") == "primary":
            primary = data
    if primary is None:
        raise Refusal(f"{path} lists no primary metadata")
    href = primary.find(f"{REPO_NS}location").get("href", "")
    if not PRIMARY_HREF.match(href):
        raise Refusal(f"the primary metadata of {path} is at '{href}', outside repodata/")
    checksum = primary.find(f"{REPO_NS}checksum")
    if checksum is None or checksum.get("type") != "sha256" or not re.fullmatch(r"[0-9a-f]{64}", checksum.text or ""):
        raise Refusal(f"{path} gives its primary metadata no sha256")
    return int(revision), href, checksum.text


DATA_HREF = re.compile(r"repodata/[0-9a-f]{64}-[a-z_]+\.(xml|sqlite)\.(gz|bz2|xz|zst)")


def locations(path):
    """Every file the index lists, with the sha256 it gives it, each in the form createrepo_c writes."""
    root = ET.fromstring(read_bounded(path, MAX_XML_BYTES))
    out = []
    for data in root.findall(f"{REPO_NS}data"):
        href = data.find(f"{REPO_NS}location").get("href", "")
        checksum = data.find(f"{REPO_NS}checksum")
        if not DATA_HREF.fullmatch(href) or checksum is None or checksum.get("type") != "sha256" or not re.fullmatch(r"[0-9a-f]{64}", checksum.text or ""):
            raise Refusal(f"{path} lists '{href}', which is not a file of the form the channel publishes")
        out.append((href, checksum.text))
    return out


def packages(repomd, primary_path):
    _revision, href, want = parse_repomd(repomd)
    raw = read_bounded(primary_path, MAX_XML_BYTES)
    if hashlib.sha256(raw).hexdigest() != want:
        raise Refusal(f"{primary_path} does not match the checksum {repomd} gives it")
    if not href.startswith("repodata/" + want):
        raise Refusal(f"the name of the primary metadata of {repomd} is not its checksum")
    # read with a ceiling: a file that is a few kilobytes and a few gigabytes once decompressed is never decompressed whole
    with gzip.GzipFile(fileobj=io.BytesIO(raw)) as stream:
        xml = stream.read(MAX_PRIMARY_BYTES + 1)
    if len(xml) > MAX_PRIMARY_BYTES:
        raise Refusal("the primary metadata is too large once decompressed")
    rows = []
    for pkg in ET.fromstring(xml).findall(f"{COMMON_NS}package"):
        name = pkg.findtext(f"{COMMON_NS}name")
        arch = pkg.findtext(f"{COMMON_NS}arch")
        version = pkg.find(f"{COMMON_NS}version")
        checksum = pkg.find(f"{COMMON_NS}checksum")
        location = pkg.find(f"{COMMON_NS}location").get("href")
        if not (name and NAME.match(name) and arch and NAME.match(arch)) or version is None or checksum is None:
            raise Refusal("a package of the primary metadata has a malformed name, architecture or version")
        rows.append((name, arch, version.get("epoch", "0"), version.get("ver"), version.get("rel"),
                     checksum.text, location))
    return rows


SAFE_EVR = re.compile(r"[A-Za-z0-9._+~^-]{1,128}")


def vercmp_pairs(pairs):
    """rpm's own answer (-1, 0, 1) for each pair of version or release strings, in one call of rpm."""
    if not pairs:
        return []
    for pair in pairs:
        for text in pair:
            if not SAFE_EVR.fullmatch(text or ""):
                raise Refusal(f"the version or release '{text}' is not one rpm is asked about")
    table = ",".join('{"%s","%s"}' % pair for pair in pairs)
    program = "%{lua: local t = {" + table + "}; local r = {}; for i, p in ipairs(t) do r[#r + 1] = rpm.vercmp(p[1], p[2]) end; print(table.concat(r, \" \"))}"
    done = subprocess.run(["rpm", "--eval", program], capture_output=True, text=True, timeout=60, check=False)
    answers = done.stdout.split()
    if done.returncode != 0 or len(answers) != len(pairs) or any(a not in ("-1", "0", "1") for a in answers):
        raise Refusal("rpm did not answer the version comparison")
    return [int(a) for a in answers]


def evrcmp_all(pairs):
    """For pairs of (epoch, version, release) triples: -1, 0, 1 each, the epoch compared as the number it is."""
    out = [None] * len(pairs)
    todo = []
    for n, (a, b) in enumerate(pairs):
        ea, eb = int(a[0]), int(b[0])
        if ea != eb:
            out[n] = 1 if ea > eb else -1
        else:
            todo.append(n)
    for field in (1, 2):
        pending = [n for n in todo if out[n] is None]
        if not pending:
            break
        answers = vercmp_pairs([(pairs[n][0][field], pairs[n][1][field]) for n in pending])
        for n, answer in zip(pending, answers):
            if answer:
                out[n] = answer
    return [0 if o is None else o for o in out]


def order(argv):
    served = {(r[0], r[1]): r for r in packages(argv[0], argv[1])}
    following = {(r[0], r[1]): r for r in packages(argv[2], argv[3])}
    retired = set()
    if len(argv) > 4:
        for line in read_bounded(argv[4], 1 << 20).decode("ascii").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                retired.add(line)
    problems = []
    if parse_repomd(argv[2])[0] <= parse_repomd(argv[0])[0]:
        problems.append(f"revision {parse_repomd(argv[2])[0]} is not greater than the served {parse_repomd(argv[0])[0]}")
    keys = [key for key in sorted(served) if key in following]
    verdicts = dict(zip(keys, evrcmp_all([(served[k][2:5], following[k][2:5]) for k in keys])))
    for key, old in sorted(served.items()):
        new = following.get(key)
        if new is None:
            if old[0] not in retired:
                problems.append(f"{old[0]}.{old[1]} is served and would be dropped")
            continue
        cmp = verdicts[key]
        if cmp > 0:
            problems.append(f"{old[0]}.{old[1]} would go from {old[2]}:{old[3]}-{old[4]} back to {new[2]}:{new[3]}-{new[4]}")
        elif cmp == 0 and old[5] != new[5]:
            problems.append(f"{old[0]}-{old[3]}-{old[4]}.{old[1]} is served and would be published again with other bytes")
    for line in problems:
        print(f"::error::{line}", file=sys.stderr)
    return 1 if problems else 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        cmd = argv[1]
        if cmd == "revision" and len(argv) == 3:
            print(parse_repomd(argv[2])[0])
        elif cmd == "primary" and len(argv) == 3:
            print(parse_repomd(argv[2])[1])
        elif cmd == "packages" and len(argv) == 4:
            for row in packages(argv[2], argv[3]):
                print("\t".join(row))
        elif cmd == "vercmp" and len(argv) == 4:
            print(vercmp_pairs([(argv[2], argv[3])])[0])
        elif cmd == "locations" and len(argv) == 3:
            for href, digest in locations(argv[2]):
                print(f"{href}\t{digest}")
        elif cmd == "order" and len(argv) in (6, 7):
            return order(argv[2:])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except (Refusal, ET.ParseError, OSError, EOFError, gzip.BadGzipFile, AttributeError, ValueError) as err:
        print(f"::error::repo-state: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

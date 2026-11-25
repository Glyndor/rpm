# Contract: rpm packages of a Glyndor product (channel `Glyndor/rpm`)

For the agent of each product (podup and epistle, and later helmly, helmly-agent and epistle-panel). Podman has its
own contract. Nothing here is published until a release carries the files below; the day it does, the channel
picks the release up with no change to the channel.

## 1. What the release attaches

For a tag `vX.Y.Z` (stable only, no suffix), per architecture `A` in `x86_64`, `aarch64` (a product that is not
architecture dependent, such as a Node application, ships one `noarch` file instead):

| asset | content |
|---|---|
| `<name>-X.Y.Z-1.glyndor.any.<A>.rpm` | the package |
| `<name>-X.Y.Z-1.glyndor.any.<A>.rpm.sig` | raw 64-byte Ed25519 signature of the exact bytes of the `.rpm`, made with the unified release key (`keyring/glyndor-release-ed25519.b64`), the same shape as `<deb>.sig` |
| `<name>-X.Y.Z-1.glyndor.any.<A>.rpm.mldsa65.sig` | when the second release key exists: raw 3309-byte ML-DSA-65 signature of the same bytes |

Provenance attestation covers each `.rpm` (and `.sig`), made by the release workflow of the product
(`release.yml`; `release-dashboard.yml` for helmly), checked with `gh attestation verify`.

No other asset may end in `.rpm`, `.rpm.sig` or `.rpm.mldsa65.sig`. Every signature is at most 4096 bytes and
every `.rpm` at most 300 MiB.

## 2. Header fields (read from the signed bytes, never from the file name)

| field | value |
|---|---|
| `Name` | the product name, exactly (`podup`, `epistle`, `helmly`, `helmly-agent`, `epistle-panel`) |
| `Version` | the tag without `v`: `X.Y.Z` |
| `Release` | `1.glyndor.any` (`any` says the package serves every distribution; a build is never redone for the same tag) |
| `Epoch` | none (0) |
| `Arch` | `x86_64`, `aarch64` or `noarch`, equal to the last field of the file name |
| `Vendor` | `Glyndor` |
| `Packager` | `Glyndor <noreply@glyndor.net>` |
| package format | 4 (`%_rpmformat 4`; rpm 6.0.x writes 6 by default and rpm 4.16 cannot read it) |
| `Obsoletes`, `Conflicts`, `Recommends`, `Suggests`, `Supplements`, `Enhances` | none |
| `Provides` | only the names of section 2b (so `AutoProv: no`: a bundled library must not provide its soname) |

File name: exactly `<Name>-<Version>-<Release>.<Arch>.rpm`. A name that does not match its own header is refused.

## 2b. What the package may carry (checked from the signed bytes)

* **Files**: only under these paths, in canonical form (starting with one `/`, no `//`, no `.` or `..` component,
  no control character; `/bin`, `/sbin`, `/lib` and `/lib64` are read as their targets under `/usr`), where `<name>` is
  the product name: `/usr/bin/<name>`, `/usr/lib/<name>/`, `/usr/lib64/<name>/`, `/usr/libexec/<name>/`,
  `/usr/lib/systemd/system/<name>*`, `/usr/lib/sysusers.d/<name>*`, `/usr/lib/tmpfiles.d/<name>*`,
  `/usr/share/{doc,licenses}/<name>/`, `/usr/share/man/man[1-8]/<name>*`, the bash, zsh (`_<name>`) and fish
  (`<name>.fish`) completions, `/etc/<name>/` and `/var/lib/<name>/`. The list is `config/paths.txt` in `Glyndor/rpm`;
  a product that needs another path asks for it in a pull request there. Nothing may be installed under the package
  manager's own folders (`/etc/yum.repos.d`, `/etc/zypp`, `/etc/pki/rpm-gpg`, `/usr/lib/rpm`, `/etc/dnf`).
* **Kind of each entry**: regular files, folders and symbolic links only (no device, pipe or socket); no setuid or
  setgid bit and no file capability on anything. A link is admitted only when it is not where the rule of its kind admits
  children (a link at `/usr/lib/<name>/x` could take later files anywhere), and where it points, resolved by its text
  against its folder, is a path its kind may install; the few links outside that (podman-docker's `docker` and
  podmansh's `podmansh`, which point at `podman`) are written in `config/links.txt`.
* **Interpreter of a scriptlet**: `/bin/sh` alone, with no argument (a package that needs
  `rpmlib(ScriptletInterpreterArgs)` is refused), and no scriptlet flags. The scriptlets are compared as one text per
  tag with its length, so the same text cannot be split another way between `%pre` and `%post`.
* **Scriptlets** (`%pre`, `%post`, `%preun`, `%postun`, `%pretrans`, `%posttrans`, `%verifyscript`, and their programs): none.
  A scriptlet is admitted only as the exact text a person has read and listed in `config/scriptlets.txt`; the refusal prints
  the hash to list. **Triggers and file triggers**: never. Two kinds may carry scriptlets, and only the ones named here:
  `podman` (a `%pretrans` and a `%posttrans`, one text per distribution id) and the kind **service** below.
* **Kind `service`** (a product that installs a systemd unit; none yet; epistle the day it ships one). Without a
  scriptlet, removing the package with `dnf` leaves the process running with no binary, so a service MUST carry exactly the
  expansion of the three systemd macros for its unit and nothing else: `%post` = `%systemd_post <unit>`, `%preun` =
  `%systemd_preun <unit>`, `%postun` = `%systemd_postun_with_restart <unit>`, with `Requires: systemd`. No other scriptlet
  (a `%pre`, a `%pretrans`, a `%posttrans`, a `%verifyscript`, a trigger) is admitted, and a service with no scriptlet is
  refused. The text is compared by equality: the hash of all the scriptlets together must be listed under the key
  `service:<product>` (`service:<product>:<id>` if the product is ever built per id instead of one `.any` package). The
  expansion is the one of the image the product builds on (AlmaLinux 9, the family of Fedora, EL and Amazon Linux; openSUSE
  writes another text), so build with `rpmbuild` in that image and, if the channel refuses the package, list the hash it prints
  in a pull request here after reading the text. A product asks to be a service in `config/products.txt` and lists its `Requires`
  in `config/service-requires.txt`.
* **Relations**: `Provides` only `<name>`, `<name>(x86-64)` / `<name>(aarch-64)` and `config(<name>)` (build with
  `AutoProv: no`); `Requires` only `rpmlib(...)`, `config(<name>)`, `/bin/sh` (when a scriptlet is listed), podman, podup,
  systemd, ca-certificates and nftables; `Recommends`, `Suggests`, `Supplements`, `Enhances`, `Obsoletes`, `Conflicts`:
  none. (`config/relations.txt`.) A **service** may require only what rpm adds by itself (`rpmlib(...)`, `config(<name>)`,
  `/bin/sh`, `systemd`) and the closed list of its product in `config/service-requires.txt`, compared with the comparison
  and the version (for example `podman >= 6.2.0`),
  Another version, another name or a missing comparison refuses the release.
* Names are read as records, one per line, and a name with a line break or a control character in it refuses the release:
  the number of records must equal the number of entries the header counts.
* Two products must not ship the same file path: the channel refuses a repository in which two packages do.
* The name `glyndor-release` is reserved for the channel's own bootstrap package.

## 3. How the channel decides the distributions

By `Release`: `.glyndor.any` is served in all seven ids (`fc45 fc44 el9 el10 amzn2023 leap161 tumbleweed`) and in
both architectures it declares. The package therefore has to be a static binary or architecture-independent: it
must not depend on a distribution library newer than the oldest id (EL 9, glibc 2.34), and its `Requires` must be
satisfiable on all of them. A product that cannot meet this ships one package per id with `Release` ending in
`.glyndor.<id>` instead; ask the channel before doing it.

## 4. What the channel refuses

A signature that does not verify (the `.sig` is checked first, before anything opens the package); a file the
contract does not name; two files for one architecture; a symlink; a name with `/`, `..` or glob characters; a
size over the cap; a field different from the table; a package of another product under this product's
release; a version that is not the tag's; an older version than the one served; and, once the product is listed
in `keyring/pq-required-products`, a missing or invalid `.mldsa65.sig`.

## 5. How to test your side

`gh release download vX.Y.Z --pattern '*.rpm*'` and `rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}|%{EPOCH}|%{ARCH}|%{VENDOR}|%{PACKAGER}|%{RPMFORMAT}\n' <file>`
must print exactly the table above. The command needs rpm 6 or later (for example the `fedora:45` image or Ubuntu 26.04): `%{RPMFORMAT}` is not a tag of rpm 4.16 (EL 9), which answers `unknown tag`. The channel runs the same check with rpm 6.0.1 (`scripts/verify/admit-release.sh` refuses to start with an rpm that lacks the tag), and a package of format 6 is refused there. `scripts/verify/admit-release.sh` in `Glyndor/rpm` is the check the channel runs.

#!/usr/bin/env bash
# Helpers the rpm tests source: tiny packages built with rpmbuild (no payload, so a package is a
# few KiB), a throwaway release key, and whole fake releases laid out the way the contract says.
# Needs rpmbuild, python3 with `cryptography`. Every function works under $FX_WORK.

FX_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX_REPO="$(cd "$FX_HERE/../../.." && pwd)"
FX_PY="python3 -I"

fx_init() { # <workdir>: a release key pair and the keyring directory the scripts read
	FX_WORK="$1"
	mkdir -p "$FX_WORK/keys" "$FX_WORK/keyring"
	$FX_PY "$FX_HERE/release-key.py" gen-ed "$FX_WORK/keys"
	cp "$FX_WORK/keys/ed.b64" "$FX_WORK/keyring/glyndor-release-ed25519.b64"
	: > "$FX_WORK/keyring/glyndor-release-mldsa65.b64"
	: > "$FX_WORK/keyring/pq-required-products"
}

# fx_rpm <out-dir> <name> <version> <release> <arch> [key=value ...]
# keys: epoch vendor packager format provides obsoletes conflicts (relations are space separated)
# fx_items <list>: the items of a relation list, one per line; split at `;` when there is one (an item may then hold
# spaces, as `podman >= 6.2.0`), at spaces otherwise
fx_items() {
	if [[ "$1" == *\;* ]]; then tr ';' '\n' <<< "$1"; else tr ' ' '\n' <<< "$1"; fi | grep -v '^$' || true
}

fx_rpm() {
	local out="$1" name="$2" version="$3" release="$4" arch="$5"; shift 5
	local epoch="" vendor="Glyndor" packager="Glyndor <noreply@glyndor.net>" format=4
	local requires="" recommends="" suggests="" supplements="" enhances="" post="" pretrans="" verifyscript="" preun="" preuntrans="" postuntrans="" posttrans="" dirs="" postun="" postprog="" pre="" symlink="" attr="" devfile="" bigfile="" dirattr="" owner="" payload="" trigger="" filetrigger="" provides="" obsoletes="" conflicts="" kv top spec rel
	for kv in "$@"; do
		case "$kv" in
			epoch=*) epoch="${kv#*=}" ;; vendor=*) vendor="${kv#*=}" ;; packager=*) packager="${kv#*=}" ;;
			format=*) format="${kv#*=}" ;; provides=*) provides="${kv#*=}" ;;
			obsoletes=*) obsoletes="${kv#*=}" ;; conflicts=*) conflicts="${kv#*=}" ;;
			requires=*) requires="${kv#*=}" ;; recommends=*) recommends="${kv#*=}" ;; suggests=*) suggests="${kv#*=}" ;;
			supplements=*) supplements="${kv#*=}" ;; enhances=*) enhances="${kv#*=}" ;; post=*) post="${kv#*=}" ;; pretrans=*) pretrans="${kv#*=}" ;;
			verifyscript=*) verifyscript="${kv#*=}" ;; preun=*) preun="${kv#*=}" ;; preuntrans=*) preuntrans="${kv#*=}" ;; posttrans=*) posttrans="${kv#*=}" ;; postprog=*) postprog="${kv#*=}" ;; pre=*) pre="${kv#*=}" ;; symlink=*) symlink="${kv#*=}" ;; bigfile=*) bigfile="${kv#*=}" ;; dirattr=*) dirattr="${kv#*=}" ;; owner=*) owner="${kv#*=}" ;; attr=*) attr="${kv#*=}" ;; dev=*) devfile="${kv#*=}" ;; postun=*) postun="${kv#*=}" ;; dir=*) dirs="${kv#*=}" ;; postuntrans=*) postuntrans="${kv#*=}" ;;
			file=*) payload="${kv#*=}" ;; trigger=*) trigger="${kv#*=}" ;; filetrigger=*) filetrigger="${kv#*=}" ;;
		esac
	done
	top="$(mktemp -d "$FX_WORK/rb.XXXXXX")"; mkdir -p "$top"/{SPECS,BUILD,RPMS,SRPMS,SOURCES}
	spec="$top/SPECS/p.spec"
	{
		echo "Name: $name"; echo "Version: $version"; echo "Release: $release"
		[ -z "$epoch" ] || echo "Epoch: $epoch"
		echo "Summary: fixture"; echo "License: MIT"
		[ -z "$vendor" ] || echo "Vendor: $vendor"
		[ -z "$packager" ] || echo "Packager: $packager"
		[ "$arch" != noarch ] || echo "BuildArch: noarch"
		while IFS= read -r p; do echo "Provides: $p"; done < <(fx_items "$provides")
		while IFS= read -r p; do echo "Obsoletes: $p"; done < <(fx_items "$obsoletes")
		while IFS= read -r p; do echo "Conflicts: $p"; done < <(fx_items "$conflicts")
		while IFS= read -r p; do echo "Requires: $p"; done < <(fx_items "$requires")
		while IFS= read -r p; do echo "Recommends: $p"; done < <(fx_items "$recommends")
		while IFS= read -r p; do echo "Suggests: $p"; done < <(fx_items "$suggests")
		while IFS= read -r p; do echo "Supplements: $p"; done < <(fx_items "$supplements")
		while IFS= read -r p; do echo "Enhances: $p"; done < <(fx_items "$enhances")
		printf '%%description\nfixture\n'
		if [ -n "$payload" ]; then printf '%%install\nmkdir -p %%{buildroot}%s\ntouch %%{buildroot}%s\n' "$(dirname "$payload")" "$payload"; fi
		[ -z "$symlink" ] || printf '%%install\nmkdir -p %%{buildroot}%s\nln -s %s %%{buildroot}%s\n' "$(dirname "${symlink%%:*}")" "${symlink#*:}" "${symlink%%:*}"
		[ -z "$attr" ] || printf '%%install\nmkdir -p %%{buildroot}%s\ntouch %%{buildroot}%s\n' "$(dirname "${attr#*:}")" "${attr#*:}"
		[ -z "$bigfile" ] || printf '%%install\nmkdir -p %%{buildroot}%s\nhead -c %s /dev/zero > %%{buildroot}%s\n' "$(dirname "${bigfile%%:*}")" "${bigfile#*:}" "${bigfile%%:*}"
		[ -z "$dirattr" ] || printf '%%install\nmkdir -p %%{buildroot}%s\n' "${dirattr#*:}"
		[ -z "$owner" ] || printf '%%install\nmkdir -p %%{buildroot}%s\ntouch %%{buildroot}%s\n' "$(dirname "${owner#*:*:}")" "${owner#*:*:}"
		printf '%%files\n'
		[ -z "$owner" ] || printf '%%attr(-,%s,%s) %s\n' "${owner%%:*}" "$(o="${owner#*:}"; echo "${o%%:*}")" "${owner#*:*:}"
		[ -z "$dirattr" ] || printf '%%attr(%s,root,root) %%dir %s\n' "${dirattr%%:*}" "${dirattr#*:}"
		[ -z "$bigfile" ] || printf '%s\n' "${bigfile%%:*}"
		[ -z "$symlink" ] || printf '%s\n' "${symlink%%:*}"
		[ -z "$attr" ] || printf '%%attr(%s,root,root) %s\n' "${attr%%:*}" "${attr#*:}"
		[ -z "$devfile" ] || printf '%%dev(c,1,3) %s\n' "$devfile"
		[ -z "$payload" ] || printf '%s\n' "$payload"
		[ -z "$dirs" ] || printf '%%dir %s\n' "$dirs"
		[ -z "$post" ] || printf '%%post%s\n%s\n' "${postprog:+ -p $postprog}" "$post"
		[ -z "$pre" ] || printf '%%pre\n%s\n' "$pre"
		[ -z "$pretrans" ] || printf '%%pretrans\n%s\n' "$pretrans"
		[ -z "$verifyscript" ] || printf '%%verifyscript\n%s\n' "$verifyscript"
		[ -z "$preun" ] || printf '%%preun\n%s\n' "$preun"
		[ -z "$postun" ] || printf '%%postun\n%s\n' "$postun"
		[ -z "$posttrans" ] || printf '%%posttrans\n%s\n' "$posttrans"
		[ -z "$preuntrans" ] || printf '%%preuntrans\n%s\n' "$preuntrans"
		[ -z "$postuntrans" ] || printf '%%postuntrans\n%s\n' "$postuntrans"
		[ -z "$trigger" ] || printf '%%triggerin -- %s\ntrue\n' "$trigger"
		[ -z "$filetrigger" ] || printf '%%transfiletriggerin -- %s\ntrue\n' "$filetrigger"
	} > "$spec"
	rpmbuild --define "_topdir $top" --define "_rpmformat $format" --define '_build_name_fmt %{NAME}.rpm' \
		--target "${arch}-linux" -bb "$spec" > "$top/log" 2>&1 || { cat "$top/log" >&2; return 1; }
	rel="$(find "$top/RPMS" -name '*.rpm')"
	mv "$rel" "$out/${name}-${version}-${release}.${arch}.rpm"
	rm -rf "$top"
}

fx_sign() { # <file>: the Ed25519 .sig of the test release key
	$FX_PY "$FX_HERE/release-key.py" sign-ed "$FX_WORK/keys/ed.seed" "$1"
}

# fx_static_release <dir> <product> <version> <arch,arch|noarch>: the assets a static product attaches
fx_static_release() {
	local dir="$1" product="$2" version="$3" arch
	mkdir -p "$dir"
	for arch in ${4//,/ }; do
		fx_rpm "$dir" "$product" "$version" "1.glyndor.any" "$arch" provides="$product" || return 1
		fx_sign "$dir/${product}-${version}-1.glyndor.any.${arch}.rpm"
	done
}

# fx_podman_release <dir> <tag-version V> <R>: the whole set of config/podman-packages.txt
fx_podman_release() {
	local dir="$1" v="$2" r="$3" id name akind epoch vrule arch ver rel
	mkdir -p "$dir"
	while IFS=$'\t' read -r id name akind epoch vrule; do
		for arch in $([ "$akind" = noarch ] && echo noarch || echo x86_64 aarch64); do
			ver="$v+r$r"; [ "$vrule" = extra ] && ver="1.31"
			rel="$r.glyndor.$id"
			case "$vrule$name" in
				corepodman) prov="podman podman-remote netavark aardvark-dns containers-common"; obs="netavark aardvark-dns" ;;
				*) prov="$name"; obs="" ;;
			esac
			fx_rpm "$dir" "$name" "$ver" "$rel" "$arch" epoch="$epoch" provides="$prov" obsoletes="$obs" || return 1
			fx_sign "$dir/${name}-${ver}-${rel}.${arch}.rpm"
		done
	done < <(grep -vE '^[[:space:]]*(#|$)' "$FX_REPO/config/podman-packages.txt")
}

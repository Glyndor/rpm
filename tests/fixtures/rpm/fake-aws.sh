#!/usr/bin/env bash
# A stand-in for the `aws` CLI that the publication tests put first on PATH: a bucket is the folder
# $FAKE_S3/<bucket>/ and an object's sha256 metadata sits beside it. Every call goes to $FAKE_S3_LOG.
#   FAKE_S3_FAIL     a substring of a key whose upload fails
#   FAKE_S3_CORRUPT  a substring of a key whose bytes are stored altered (a read back that differs)
printf '%s\n' "$*" >> "${FAKE_S3_LOG:-/dev/null}"
args=("$@"); sub="$1 $2"; shift 2
opt() { # <name>: the value after --name
	local i
	for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "--$1" ] && { echo "${args[$((i + 1))]}"; return; }; done
}
obj() { echo "$FAKE_S3/$1/o/$2"; }
meta() { echo "$FAKE_S3/$1/m/$2"; }
case "$sub" in
	"s3api list-objects-v2")
		b="$(opt bucket)"; mkdir -p "$FAKE_S3/$b/o"
		cd "$FAKE_S3/$b/o" && find . -type f -printf '%P\t%T@\n' | sort | while IFS=$'\t' read -r k t; do
			printf '{"Key":"%s","LastModified":"%s"}\n' "$k" "$(date -u -d "@${t%.*}" +%Y-%m-%dT%H:%M:%S+00:00)"
		done | jq -s '{Contents: .}' ;;
	"s3api head-object")
		o="$(obj "$(opt bucket)" "$(opt key)")"; [ -f "$o" ] || { echo "An error occurred (404) when calling the HeadObject operation" >&2; exit 254; }
		m="$(meta "$(opt bucket)" "$(opt key)")"
		jq -n --arg s "$(cat "$m" 2>/dev/null || true)" '{Metadata: (if $s == "" then {} else {sha256: $s} end)}' ;;
	"s3api delete-object") rm -f "$(obj "$(opt bucket)" "$(opt key)")" "$(meta "$(opt bucket)" "$(opt key)")" ;;
	"s3 cp")
		src="$1"; dst="$2"
		case "$dst" in
			s3://*)
				rest="${dst#s3://}"; b="${rest%%/*}"; k="${rest#*/}"
				case "$k" in *"${FAKE_S3_FAIL:-@@none@@}"*) echo "upload failed: $k" >&2; exit 1 ;; esac
				mkdir -p "$(dirname "$(obj "$b" "$k")")" "$(dirname "$(meta "$b" "$k")")"
				cp "$src" "$(obj "$b" "$k")"
				case "$k" in *"${FAKE_S3_CORRUPT:-@@none@@}"*) printf 'x' >> "$(obj "$b" "$k")" ;; esac
				m="$(opt metadata)"; if [ -n "$m" ]; then printf '%s' "${m#sha256=}" > "$(meta "$b" "$k")"; else rm -f "$(meta "$b" "$k")"; fi ;;
			*)
				rest="${src#s3://}"; b="${rest%%/*}"; k="${rest#*/}"
				[ -f "$(obj "$b" "$k")" ] || { echo "download failed: $k" >&2; exit 1; }
				cp "$(obj "$b" "$k")" "$dst" ;;
		esac ;;
	*) echo "fake aws: unexpected call: $*" >&2; exit 2 ;;
esac

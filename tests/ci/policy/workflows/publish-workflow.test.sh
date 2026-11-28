#!/usr/bin/env bash
#
# The shape of .github/workflows/publish.yml, which no pull request runs: the rules of the jobs that
# sign and publish, held as tests so that an edit that breaks one is red before it merges. Each rule
# is shown to fail on a planted copy of the workflow before the real one is read.
# Requires: python3 with yaml.
# shellcheck disable=SC2016 # the patterns are the literal text of the workflow
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WF="$HERE/.github/workflows/publish.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
# audit <workflow file>: one line per violated rule; empty when the workflow keeps them all
audit() {
	python3 -I - "$1" <<'PY'
import re
import sys

import yaml

wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get(True, wf.get("on"))
out = []


def say(rule, where=""):
    out.append(f"{rule} {where}".strip())


if set(on) != {"workflow_dispatch", "schedule"}:
    say("the triggers are not exactly workflow_dispatch and schedule")
if wf.get("permissions") != {}:
    say("the workflow does not start from permissions: {}")
if wf["concurrency"]["cancel-in-progress"] is not False:
    say("a publication may be cancelled")
mode = on["workflow_dispatch"]["inputs"]["mode"]
if mode["default"] != "rehearsal" or set(mode["options"]) != {"rehearsal", "publish"}:
    say("the manual mode does not default to the rehearsal")
if not on["schedule"] or len(on["schedule"]) != 1:
    say("not exactly one schedule")

SECRET = re.compile(r"secrets\.([A-Za-z0-9_]+)")
allowed = {
    "sign": {"GLYNDOR_RPM_GPG_PRIVATE_KEY"},
    "publish": {"GLYNDOR_RPM_R2_ACCESS_KEY_ID", "GLYNDOR_RPM_R2_SECRET_ACCESS_KEY", "GLYNDOR_RPM_R2_ENDPOINT",
                "GLYNDOR_CF_PURGE_TOKEN", "GLYNDOR_CF_ZONE_ID"},
}
for name, job in wf["jobs"].items():
    if "uses" in job:
        continue  # a call of a reusable workflow has no steps; what it may do is held by the test of that workflow
    text = yaml.dump(job)
    secrets = set(SECRET.findall(text))
    perms = job.get("permissions")
    if perms != {"contents": "read"}:
        say("the permissions are not exactly contents: read in", name)
    if "timeout-minutes" not in job:
        say("no timeout-minutes in", name)
    if secrets:
        if secrets != allowed.get(name, set()):
            say(f"names the secrets {sorted(secrets)} in", name)
        if job.get("environment") != "publish":
            say("names a secret and has no environment: publish in", name)
        first = job["steps"][0]
        script = first.get("run", "")
        env = " ".join(f"{k}={v}" for k, v in first.get("env", {}).items())
        if not ('"$REF" = refs/heads/main' in script and "github.ref" in env and "github.event_name" in env and "github.sha" in env):
            say("does not open with a step that holds the event, the ref and the commit to main in", name)
        if "secrets." in yaml.dump(first):
            say("the first step reads a secret in", name)
    elif job.get("environment"):
        say("has an environment and names no secret in", name)
    for step in job["steps"]:
        uses = step.get("uses", "")
        if uses and not re.fullmatch(r"actions/[a-z-]+@[0-9a-f]{40}", uses):
            say(f"uses {uses}, not an actions/* pinned by SHA, in", name)
        if uses.startswith("actions/checkout"):
            if step["with"].get("persist-credentials") is not False:
                say("a checkout keeps its credentials in", name)
            if name != "plan" and str(step["with"].get("ref")) != "${{ github.sha }}":
                say("a checkout of something else than the commit of the run in", name)
        if uses.startswith("actions/download-artifact"):
            if "merge-multiple" in step["with"] or "runner.temp" not in step["with"].get("path", ""):
                say("an artifact is merged or downloaded into the workspace in", name)
            if not step["with"].get("name"):
                say("an artifact downloaded without its name in", name)
        run = step.get("run", "")
        if re.search(r"\bpython3?\s+-m\b|\bpip\b", run):
            say("runs python -m or pip in", name)
        if re.search(r"\$\{\{\s*(github\.event|inputs|needs)", run):
            say("an expression is interpolated into a shell program in", name)

if wf["jobs"]["rehearse"].get("environment") or SECRET.search(yaml.dump(wf["jobs"]["rehearse"])):
    say("the rehearsal reads a secret or an environment")
signing = yaml.dump(wf["jobs"]["sign"])
pub = yaml.dump(wf["jobs"]["publish"])
if "GLYNDOR_RPM_R2" in signing or "GLYNDOR_CF" in signing:
    say("the job that holds the archive key holds bucket credentials")
if "GLYNDOR_RPM_GPG" in pub:
    say("the job that uploads holds the archive key")
for n in ("sign", "publish"):
    if wf["jobs"][n].get("if", "").strip("${} ") != "needs.plan.outputs.mode == 'publish'":
        say("not conditioned on the publish mode:", n)
for n in ("rehearse",):
    if wf["jobs"][n].get("if", "").strip("${} ") != "needs.plan.outputs.mode == 'rehearsal'":
        say("not conditioned on the rehearsal mode:", n)
# what the publishing job checks for itself, because an artifact of an earlier job is data
if "digest" not in wf["jobs"]["sign"].get("outputs", {}) or "tree-digest.sh" not in signing:
    say("the signing job does not say the digest of its tree")
for needle, why in (("needs.sign.outputs.digest", "compares the tree with the digest the signing job gave"),
                    ("tree-digest.sh", "computes the digest of the tree it downloaded"),
                    ("check-static-files.sh", "renders the installers again from its commit"),
                    ("check-plan-age.sh", "refuses a plan that is no longer current"),
                    ("verify-tree.sh", "reads the tree again")):
    if needle not in pub:
        say("the publishing job does not check: " + why + " in", "publish")
order = [st.get("name", "") for st in wf["jobs"]["publish"]["steps"]]
def at(prefix):
    return next((i for i, n in enumerate(order) if n.startswith(prefix)), 99)
if not (at("The plan is still") < at("The artifact is") < at("Read the tree again") < at("The installers") < at("Upload to R2")):
    say("the checks of the publishing job are not before the upload, in order")
if wf["jobs"]["publish"]["needs"] != ["plan", "sign"] or wf["jobs"]["sign"]["needs"] != ["plan", "admit"]:
    say("the order plan, admit, sign, publish is not the needs of the jobs")
print("\n".join(out))
PY
}

# --- every rule shown red on a planted copy first -----------------------------------------------------
plant() { # <description> <python edit of the text s> <fragment of the expected finding>
	python3 -I - "$WF" "$WORK/planted.yml" "$2" <<'PY'
import sys
s = open(sys.argv[1]).read()
exec(sys.argv[3])
open(sys.argv[2], "w").write(s)
PY
	check "planted: $1" 1 "$(audit "$WORK/planted.yml" | grep -cF -- "$3")"
}
plant "a publish job without the environment" 's = s.replace("    environment: publish\n    # Bound, not yet measured: an upload", "    # Bound, not yet measured: an upload")' "has no environment: publish in publish"
plant "a publishing job that does not compare the tree with the digest" 's = s.replace("needs.sign.outputs.digest", "needs.sign.outputs.nothing")' "does not check: compares the tree with the digest"
plant "a publishing job that does not render the installers again" 's = s.replace("check-static-files.sh", "true")' "does not check: renders the installers again"
plant "a publishing job that takes any plan" 's = s.replace("check-plan-age.sh", "true")' "does not check: refuses a plan"
plant "a signing job with no digest of its tree" 's = s.replace("      digest: ${{ steps.digest.outputs.digest }}\n", "      other: x\n")' "does not say the digest of its tree"
plant "the installers checked after the upload" 's = s.replace("      - name: The installers and the index page are the ones this commit renders\n", "      - name: Z after\n")' "not before the upload, in order"
plant "a sign job without the environment" 's = s.replace("    environment: publish\n    outputs:", "    outputs:")' "has no environment: publish in sign"
plant "a guard that no longer names main" 's = s.replace("refs/heads/main ] || { echo \"::error::publishing", "refs/heads/dev ] || { echo \"::error::publishing")' "does not open with a step that holds"
plant "a secret in the rehearsal" 's = s.replace("          EPOCH: ${{ needs.plan.outputs.epoch }}\n        run: bash scripts/publish/rehearse-tree.sh", "          EPOCH: ${{ needs.plan.outputs.epoch }}\n          K: ${{ secrets.GLYNDOR_RPM_GPG_PRIVATE_KEY }}\n        run: bash scripts/publish/rehearse-tree.sh")' "the rehearsal reads a secret"
plant "the bucket credentials in the signing job" 's = s.replace("          PRODUCTS: ${{ needs.plan.outputs.products }}\n          EPOCH: ${{ needs.plan.outputs.epoch }}\n        run: bash scripts/publish/sign-tree.sh", "          PRODUCTS: ${{ needs.plan.outputs.products }}\n          EPOCH: ${{ needs.plan.outputs.epoch }}\n          R: ${{ secrets.GLYNDOR_RPM_R2_ENDPOINT }}\n        run: bash scripts/publish/sign-tree.sh")' "the job that holds the archive key holds bucket credentials"
plant "write permissions on a job" 's = s.replace("    environment: publish\n    # Bound, not yet measured: an upload of the new files and a purge of a few dozen URLs.\n    timeout-minutes: 30\n    permissions:\n      contents: read", "    environment: publish\n    # Bound, not yet measured: an upload of the new files and a purge of a few dozen URLs.\n    timeout-minutes: 30\n    permissions:\n      contents: write")' "the permissions are not exactly contents: read in publish"
plant "a checkout of the branch instead of the commit of the run" 's = s.replace("ref: ${{ github.sha }}", "ref: ${{ github.ref }}", 1)' "a checkout of something else than the commit of the run"
plant "a checkout of a commit another job names" 's = s.replace("ref: ${{ github.sha }}", "ref: ${{ needs.plan.outputs.sha }}", 1)' "a checkout of something else than the commit of the run"
plant "a checkout that keeps its credentials" 's = s.replace("persist-credentials: false", "persist-credentials: true", 1)' "keeps its credentials"
plant "artifacts merged" 's = s.replace("          name: admitted\n          path: ${{ runner.temp }}/admitted\n      - name: Install rpm and createrepo_c", "          name: admitted\n          merge-multiple: true\n          path: ${{ runner.temp }}/admitted\n      - name: Install rpm and createrepo_c", 1)' "merged or downloaded into the workspace"
plant "an action that is not pinned" 's = s.replace("actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9", "actions/upload-artifact@v4", 1)' "not an actions/* pinned by SHA"
plant "a third party action" 's = s.replace("actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9", "someone/else@cf430e030ddbb5b0abf93d22962f4752f3646cd9", 1)' "not an actions/* pinned by SHA"
plant "a pull request trigger" 's = s.replace("on:\n  workflow_dispatch:", "on:\n  pull_request:\n  workflow_dispatch:", 1)' "the triggers are not exactly"
plant "a push trigger" 's = s.replace("on:\n  workflow_dispatch:", "on:\n  push:\n  workflow_dispatch:", 1)' "the triggers are not exactly"
plant "cancel in progress" 's = s.replace("cancel-in-progress: false", "cancel-in-progress: true")' "a publication may be cancelled"
plant "a manual mode that defaults to publish" 's = s.replace("default: rehearsal", "default: publish")' "does not default to the rehearsal"
plant "a job with no timeout" 's = s.replace("    timeout-minutes: 10\n", "", 1)' "no timeout-minutes in plan"
plant "an expression in a shell program" 's = s.replace("run: bash scripts/publish/purge-cache.sh \"$ARCHIVE_URL\"", "run: bash scripts/publish/purge-cache.sh \"${{ needs.plan.outputs.sha }}\"")' "an expression is interpolated"
plant "pip in a job" 's = s.replace("          sudo apt-get install -y -qq rpm\n      - name: The artifact is the tree", "          sudo apt-get install -y -qq rpm\n          pip install something\n      - name: The artifact is the tree")' "runs python -m or pip"
plant "the publish job without the plan's mode condition" 's = s.replace("    if: ${{ needs.plan.outputs.mode == \x27publish\x27 }}\n    runs-on: ubuntu-26.04\n    environment: publish\n    # Bound, not yet measured: an upload", "    runs-on: ubuntu-26.04\n    environment: publish\n    # Bound, not yet measured: an upload")' "not conditioned on the publish mode"
plant "the archive key in the uploading job" 's = s.replace("          CF_TOKEN: ${{ secrets.GLYNDOR_CF_PURGE_TOKEN }}", "          CF_TOKEN: ${{ secrets.GLYNDOR_CF_PURGE_TOKEN }}\n          K: ${{ secrets.GLYNDOR_RPM_GPG_PRIVATE_KEY }}")' "the job that uploads holds the archive key"

# --- the real workflow ------------------------------------------------------------------------------
found="$(audit "$WF")"
check "the workflow keeps every rule" "" "$found"
[ -z "$found" ] || printf '%s\n' "$found" | sed 's/^/        /'

# --- the scripts the workflow calls exist and are the ones it names ---------------------------------
for s in plan-products admit-products readmit-products rehearse-tree sign-tree sync-tree purge-cache readback-public; do
	check "scripts/publish/$s.sh exists and is called by the workflow" 1 "$([ -f "$HERE/scripts/publish/$s.sh" ] && grep -q "scripts/publish/$s.sh" "$WF" && echo 1 || echo 0)"
done
check "the verify step reads the tree with the committed key" 1 "$(grep -c 'verify-tree.sh "$RUNNER_TEMP/tree" keyring/glyndor-rpm-key.asc' "$WF")"
check "the bucket is the one of the channel" 1 "$(grep -c 'sync-tree.sh "$RUNNER_TEMP/tree" glyndor-rpm "$work"' "$WF")"
check "no step passes the test-only options" 0 "$(grep -c -E -- '--served-key|--keyring' "$WF")"
check "no script uploads by size or syncs" 0 "$(grep -rlE -- '--size-only|s3 sync' "$HERE/scripts" | wc -l)"
check "the secret key is never an argument of gpg" 0 "$(grep -c -E 'gpg .*GLYNDOR_RPM_GPG_PRIVATE_KEY' "$HERE/scripts/publish/sign-tree.sh")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]

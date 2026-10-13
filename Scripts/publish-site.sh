#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"
repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
remote_url="$(git remote get-url origin)"
source_commit="$(git rev-parse HEAD)"
pages_type="$(gh api "repos/$repository/pages" --jq .build_type)"
pages_branch="$(gh api "repos/$repository/pages" --jq .source.branch)"
if [[ "$pages_type" != legacy || "$pages_branch" != gh-pages ]]; then
  echo "Configure GitHub Pages to publish from gh-pages at / before deploying." >&2
  exit 78
fi
if [[ -n "$(git status --porcelain -- site)" ]]; then
  echo "Commit the site changes before publishing." >&2
  exit 65
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/macscope-site.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
checkout="$temporary_dir/checkout"
git clone --quiet --depth 1 --single-branch --branch gh-pages "$remote_url" "$checkout"
mkdir "$temporary_dir/site"
git archive HEAD:site | tar -x -C "$temporary_dir/site"
rsync -a --checksum --delete --exclude=.git "$temporary_dir/site/" "$checkout/"
git -C "$checkout" add --all
if ! git -C "$checkout" diff --cached --quiet; then
  git -C "$checkout" \
    -c user.name="$(git var GIT_AUTHOR_IDENT | sed 's/ <.*//')" \
    -c user.email="$(git var GIT_AUTHOR_IDENT | sed -E 's/.*<([^>]*)>.*/\1/')" \
    commit -m "Publish site from $source_commit"
  git -C "$checkout" push origin gh-pages
fi
gh api --method POST "repos/$repository/pages/builds" --jq '{status, url}'
echo "Pages build requested. Check: gh api repos/$repository/pages/builds/latest"

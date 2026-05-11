# classify.jq — bucket PRs by file-path signal.
#
# Input:  the JSON output of `gh pr list --json ...,files,...`
# Output: same array with each PR enriched with classification fields
#
# To adapt for your repo, edit the `classify_file` function below. The
# default rules cover a TypeScript monorepo with apps/, shared/, jobs/.

def classify_file:
  if   test("^plans/")                              then "plans"
  elif test("\\.md$")                               then "docs"
  elif test("^docs/")                               then "docs"
  elif test("^\\.github/")                          then "ci"
  elif test("^dev_env/")                            then "ci"
  elif test("scripts/ci-")                          then "ci"
  elif test("/migrations/")                         then "migration"
  elif test("schema\\.ts$")                         then "schema"
  elif test("\\.spec\\.(ts|js)$")                   then "test"
  elif test("\\.test\\.(ts|js|tsx)$")               then "test"
  elif test("^tests?/")                             then "test"
  elif test("api\\.yaml$")                          then "openapi"
  elif test("\\.(ts|tsx|mts|cts|mjs|cjs|js)$")      then "code"
  elif test("package\\.json$")                      then "manifest"
  elif test("package-lock\\.json$")                 then "manifest"
  elif test("\\.sql$")                              then "sql"
  elif test("Dockerfile")                           then "ci"
  elif test("\\.ya?ml$")                            then "config"
  elif test("\\.json$")                             then "config"
  else "other" end;

def categorize_pr:
  . as $pr
  | ($pr.files | map(.path | classify_file)) as $cats
  | ($cats | unique) as $unique_cats
  | $pr + {
      file_count: ($pr.files | length),
      cats: $unique_cats,
      code_files: ($pr.files | map(select(.path | classify_file == "code")) | length),
      schema_touched:    ($cats | any(. == "schema")),
      migration_touched: ($cats | any(. == "migration")),
      openapi_touched:   ($cats | any(. == "openapi")),
      test_files: ($pr.files | map(select(.path | classify_file == "test")) | length),
      primary:
        ( if   ($unique_cats | length == 1) then $unique_cats[0]
          elif ($unique_cats | all(. == "plans" or . == "docs"))
            then "docs-only"
          elif ($unique_cats | all(. == "ci" or . == "docs" or . == "plans" or . == "config"))
            then "ci-only"
          elif ($cats | any(. == "code" or . == "schema" or . == "migration" or . == "openapi"))
            then "code-touching"
          elif ($cats | any(. == "test"))
            then "test-only"
          else "mixed-other" end )
    };

map(categorize_pr)

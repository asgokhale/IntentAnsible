# Metrics Commands — regenerating the paper's numbers

All figures in the paper are reproducible from the repo with these commands.
Run from the repo root. Re-run before any resubmission so numbers stay current.

## Line counts (LOC)

### Count real lines in one file (excludes blank lines and # comments)
    grep -vcE '^\s*(#|$)' <file>
# -v invert, -c count, -E extended regex. Pattern '^\s*(#|$)' matches a line
# that is blank or starts with # (after optional whitespace). Counting the
# INVERSE gives non-blank, non-comment "real content" lines.
# Used for: pipeline.yml (35), old master playbook (604).

### Sum real lines across several files (spec + pipeline + all vars)
    grep -vhcE '^\s*(#|$)' mydeployments/pangea/spec.yml \
        mydeployments/pangea/pipeline.yml mydeployments/pangea/vars/*.yml \
        | paste -sd+ | bc
# -h suppresses filenames so -c prints just a number per file; paste -sd+ joins
# those numbers with '+'; bc evaluates the sum. Result: total per-deployment
# input (175). NOTE the -h — without it, grep prints "file:count" and the sum breaks.

## Code counts with cloc (install: apt install cloc)

### Whole engine mechanism, excluding user data and examples
    cloc --not-match-d='(mydeployments|inv|specs/examples)' \
        roles/ tasks/ templates/ generate_runner.yml deploy.yml deploy.sh
# cloc separates blank / comment / code and groups by language. --not-match-d
# excludes directories matching the regex. Explicitly listing paths means test_*.yml
# in the root are NOT counted (they aren't mechanism). Result: 1,494 LOC total.

### Core only (the intent-compilation machinery, no roles)
    cloc generate_runner.yml deploy.yml deploy.sh tasks/ templates/
# The genuinely-new layer: compiler + templates + driver. Result: 275 LOC.

### Roles only (ported/restructured legacy automation)
    cloc roles/
# The preserved investment. Result: 1,219 LOC across 31 role dirs.
# Sanity check: 275 + 1,219 = 1,494 (core + roles = total). ✓

## Counts

### Number of roles (role directories)
    ls -d roles/*/ | wc -l
# -d lists directories themselves (the trailing / restricts to dirs). Result: 31.

## Consistency sweep — find stale numbers in the paper before submitting
    grep -nE '323|1,?231|171|900|25 statement' *.tex
# -n shows line numbers. Lists every .tex line still carrying an OLD figure so
# you can replace it. Update this pattern whenever a number changes.

## Current measured values (update the date when you re-run)
# Measured: <fill date>
#   pipeline.yml (orchestration intent)........ 35 LOC
#   spec + pipeline + vars (total input)....... 175 LOC
#   legacy master playbook (equiv. phases)..... 604 LOC
#   engine core (compiler/templates/driver).... 275 LOC
#   reusable roles (31 roles).................. 1,219 LOC
#   engine mechanism total..................... 1,494 LOC
#   design dialogue............................ 1,206,036 chars
#     -> tokens chars/3.6...................... ~335,000
#     -> tokens words x1.35.................... ~247,000
#   LLM invocations per deployment............. 0

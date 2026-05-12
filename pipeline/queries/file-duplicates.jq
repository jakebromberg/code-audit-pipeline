# file-duplicates.jq — find files with identical content.
#
# Run:  jq -rf file-duplicates.jq file-hashes.json
#
# Two-section output:
#   [exact byte clusters]               files whose raw bytes are identical
#   [whitespace-normalized clusters]    files identical after CRLF→LF and trailing-whitespace
#                                       stripping, but not byte-equal — i.e. editor / line-ending
#                                       drift between otherwise identical copies
#
# Filters out generated files (.d.ts, generated/) — duplicate codegen output is not signal.

. as $all
| ([ $all[] | select((.generated // false) != true) ]) as $files

# Section 1: exact byte duplicates. Filter 0-byte files — empty stubs aren't substantive
# duplication signal and the agent doesn't need to score them.
| ( $files
    | map(select(.size_bytes > 0))
    | group_by(.sha256)
    | map(select(length > 1))
    | map({
        sha256: .[0].sha256,
        size_bytes: .[0].size_bytes,
        members: map({package, file, size_bytes})
      })
    | sort_by(-(.members | length), -(.size_bytes))
  ) as $exact

| ( [ $exact[].members[] | "\(.package):\(.file)" ] | unique) as $exact_paths

# Section 2: whitespace-normalized duplicates that aren't in $exact (and aren't empty)
| ( $files
    | map(select(.size_normalized > 0))
    | map(select(("\(.package):\(.file)") as $p | $exact_paths | index($p) == null))
    | group_by(.sha256_normalized)
    | map(select(length > 1))
    | map({
        sha256_normalized: .[0].sha256_normalized,
        size_normalized: .[0].size_normalized,
        members: map({package, file, size_bytes, size_normalized})
      })
    | sort_by(-(.members | length), -(.size_normalized))
  ) as $norm

| (
    "=== exact byte clusters (\($exact | length)) ===\n"
    + ( $exact
        | map(
            "[\(.size_bytes) bytes, \(.members | length) copies] sha256=\(.sha256[0:12])\n"
            + (.members | map("    \(.package):\(.file)") | join("\n"))
          )
        | join("\n\n")
      )
    + "\n\n=== whitespace-normalized-only clusters (\($norm | length)) ===\n"
    + ( $norm
        | map(
            "[\(.size_normalized) bytes norm, \(.members | length) copies] sha256n=\(.sha256_normalized[0:12])\n"
            + (.members | map("    \(.package):\(.file)  raw=\(.size_bytes)  norm=\(.size_normalized)") | join("\n"))
          )
        | join("\n\n")
      )
  )

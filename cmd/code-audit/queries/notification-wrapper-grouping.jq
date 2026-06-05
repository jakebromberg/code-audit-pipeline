# notification-wrapper-grouping.jq — cluster type records that wrap the same
# `Notification.Name` value, across DIFFERENT packages. Surfaces cross-module
# notification cross-fire (multiple modules each define their own `*Message`
# type that re-wraps the same upstream `Notification.Name`).
#
# Issue: #222. Substrate signal: TypeRecord.wraps_notification_name (Swift
# extractor only — populated when a type conforms to a *NotificationMessage
# protocol AND declares a `static var name: Notification.Name { … }`). The
# extractor reads the body expression verbatim; the query joins by exact
# string equality. Convention: both wrappers spell the name the same way
# (`AVPlayer.rateDidChangeNotification`, not one as `.rateDidChangeNotification`
# and the other as the qualified form).
#
# Cross-module filter: a single package legitimately defining N wrappers for
# one upstream name is rarely a finding (the module is the abstraction
# boundary, and these would already be reviewed together). Two *different*
# modules each writing their own wrapper for the same upstream name is the
# high-signal case — the wrapper pattern was supposed to centralize the
# notification dependency, and it's been duplicated. Filter: clusters whose
# .package set has cardinality ≥ 2.
#
# Severity: ANY ≥2-member cross-module cluster surfaces here. The "both are
# observers, neither posts" refinement (#222 §4) requires call-site
# (addObserver / NotificationCenter.default.post) detection that the Swift
# extractor doesn't yet emit — deferred follow-up. Agents reviewing this
# query's output read the cluster to confirm bug-vs-pattern.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/notification-wrapper-grouping.jq catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/notification-wrapper-grouping.jq catalog.json
#
# cluster_id format:  notification-wrapper-grouping:<NotificationName>
#                     (the verbatim text from the wrapper's body expression)
#
#! query: notification-wrapper-grouping
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Types in distinct packages that wrap the same Notification.Name — likely cross-fire bugs.

include "_canonical";

[ entries[]
  | select(.wraps_notification_name != null and .wraps_notification_name != "")
]
| group_by(.wraps_notification_name)
# A lone wrapper (one type wrapping a Notification.Name in isolation) is not
# a cluster — the query targets duplicated wrapper structure across modules.
| map(select(length >= 2))
# Cross-module filter: distinct .package values ≥ 2. A single module's N
# wrappers for one upstream name aren't a cross-fire signal — review tied
# the in-module wrappers together by construction.
| map(select((map(.package) | unique | length) >= 2))
| map(. as $cluster
      | {
          cluster_id: cluster_id_single_name("notification-wrapper-grouping"; .[0].wraps_notification_name),
          query: "notification-wrapper-grouping",
          shape: "cluster",
          wraps_notification_name: .[0].wraps_notification_name,
          members: map({name, kind, package, file, line, touched_in_window})
        })
| sort_by(-(.members | length), .wraps_notification_name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.wraps_notification_name) (\(.members | length) wrappers) cid=\(.cluster_id)\n"
    + (.members
        | map("  \(if .touched_in_window then "*" else " " end) \(.name) (\(.kind)) — \(.package):\(.file):\(.line)")
        | join("\n"))
  end

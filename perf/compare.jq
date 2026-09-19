.[0].meta as $ma | .[1].meta as $mb |
"=== Comparison: A vs B ===",
"Rate: A=\($ma.rate // "n/a")/s, B=\($mb.rate // "n/a")/s",
"Dropped iterations: A=\($ma.dropped_iterations // 0), B=\($mb.dropped_iterations // 0)",
"",
(
  .[0].endpoints as $a | .[1].endpoints as $b |
  ([$a, $b] | map(keys) | add | unique) as $eps |
  $eps[] as $ep |
  (
    "=== Endpoint: " + $ep + " ===",
    "Metric        A             B             Delta (B - A)",
    "----------------------------------------------------------",
    (
      ["p50", "p95", "p99", "error_rate"][] as $m |
      ($a[$ep][$m] // 0) as $va |
      ($b[$ep][$m] // 0) as $vb |
      (((($vb - $va) * 10000 | round) / 10000)) as $diff |
      (if $diff > 0 then "+" + ($diff | tostring) else ($diff | tostring) end) as $diff_str |
      ($m + "            ")[0:13] + " " +
      ($va | tostring + "             ")[0:13] + " " +
      ($vb | tostring + "             ")[0:13] + " " +
      $diff_str
    ),
    ""
  )
)

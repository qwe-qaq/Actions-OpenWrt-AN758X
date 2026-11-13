# =============================================================
# cache-roll.jq —— 从 gh cache list 的 JSON 里挑出「该删的旧代」
#
#   用法：gh cache list -R <repo> --limit 200 --json id,key,createdAt > all.json
#         jq -r -f scripts/cache-roll.jq all.json      → 每行 "<id>	<key>"
#
#   三类 key 的分组方式：
#     工具链缓存  ponwrt-<源>-<分支>-<soc>-<mode>-<sha40>      剥末尾 40 位 sha
#     工具链早期  同上 + "-early"                               先剥 -early 再剥 sha
#     dl 缓存     ponwrt-dl-<源>-<分支>-<YYYYWW>               剥末尾 6 位周号
#   三次 sub 串起来而不是正则择一（a|b），只为少一个出错面。
#
#   ★ 每组优先保留「不带 -early 的正式 key」：正式版含编译阶段才带出来的
#     hostpkg，-early 只有 tools/toolchain，仅在超时被 cancel 时保底。
#     不能只按 createdAt 取最新 —— 同提交号重跑时 -early 反而更新，会把完整的
#     正式版删掉。组内一条正式 key 都没有时，才保留 -early。
#   ★ dl 只留最新一代：它只增不减，新一代是旧一代的超集。
#     （前提：只在 make download 成功后才存，见 build-ponwrt.yml。）
# =============================================================
[ .[]
  | select(.key | startswith("ponwrt-"))
]
| group_by(.key
    | sub("-early$"; "")
    | sub("-[0-9a-f]{40}$"; "")
    | sub("-[0-9]{6}$"; ""))
| map(
    (sort_by(.createdAt | fromdate) | reverse) as $g
    | ($g | map(select(.key | endswith("-early") | not)) | first) as $keep
    | if $keep then ($g | map(select(.key != $keep.key)))
      else ($g | .[1:])
      end
  )
| flatten
| .[] | [.id, .key] | @tsv

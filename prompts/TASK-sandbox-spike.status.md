2026-10-12 11:08 | step 1 | done | 创建 Scripts/sandbox-spike/probe.swift（248 行，10 项矩阵） | 运行探针
2026-10-12 11:14 | step 2 | done | 首轮 8/10：#5 /var firmlink 未 realpath、#8/#9 代理 env 污染；定位为环境/路径问题非通路问题 | 修复探针
2026-10-12 11:14 | step 3 | done | 修复 realpath + unset 代理 + #9 重试判定后 10/10 PASS，swift Scripts/sandbox-spike/probe.swift → PROBE_EXIT=0；#9 实测抓到 exit=0 | 写报告
2026-10-12 11:14 | step 4 | done | 报告 notes/sandbox-spike-report.md（141 行：矩阵逐项证据、拒绝特征清单、base profile 模板、踩坑 5 条）；复跑 PASS 10/10 PROBE_EXIT=0 | 任务完成，上报 Owner

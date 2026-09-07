import SwiftUI

/// 跑步详情 ⓘ 弹层：含义 + 本场数据 + 结合本场的一条建议。
enum MetricGuideKind: String, Identifiable, Hashable {
    case hr, hrZone, pace, paceZone, split, stride, cadence, vo, gct, elev
    var id: String { rawValue }
}

struct MetricGuideFact: Hashable {
    let label: String
    let value: String
}

struct MetricGuideContent: Identifiable {
    let kind: MetricGuideKind
    let kicker: String
    let title: String
    let meaning: String
    let facts: [MetricGuideFact]
    let advice: String

    var id: MetricGuideKind { kind }
}

enum MetricGuideAdvisor {
    static func content(kind: MetricGuideKind,
                        record: WorkoutRecord,
                        detailed: WorkoutRecord,
                        peerAvgPace: Double?) -> MetricGuideContent {
        let pack = advicePack(kind: kind, record: record, detailed: detailed, peerAvgPace: peerAvgPace)
        let meta = meaning(for: kind)
        return MetricGuideContent(
            kind: kind,
            kicker: meta.kicker,
            title: meta.title,
            meaning: meta.meaning,
            facts: pack.facts,
            advice: pack.advice
        )
    }

    private static func meaning(for kind: MetricGuideKind) -> (kicker: String, title: String, meaning: String) {
        switch kind {
        case .hr:
            return ("强度", "心率", "心脏每分钟跳动次数。平均看整场负担，最高看有没有顶上去。结合区间一起看，比只看一个数字更准。")
        case .hrZone:
            return ("强度", "心率区间", "按最大心率百分比分成五区：热身 <60% · 燃脂 60–70% · 有氧耐力 70–80% · 无氧耐力 80–90% · 极限 ≥90%。")
        case .pace:
            return ("速度", "配速", "跑完一公里要多少时间。数字越小越快。平均看整场节奏，最佳通常来自最快的一公里。")
        case .paceZone:
            return ("速度", "配速区间", "相对本次均速：轻松偏慢，稳态巡航，节奏略快，间歇 / 冲刺明显加速。")
        case .split:
            return ("结构", "分段", "每一公里的用时、配速和心率。绿色行是最快公里，用来看哪一段加速、哪一段掉速。")
        case .stride:
            return ("跑姿", "步幅", "每一步的长度。休闲跑常见 0.9–1.2 米。想跑快，优先提步频，而不是硬拉大步。")
        case .cadence:
            return ("跑姿", "步频", "每分钟落地点数。休闲跑常见 160–180。过低再配过大步幅，膝盖冲击往往更明显。")
        case .vo:
            return ("跑姿", "垂直振幅", "身体上下起伏的厘米数。常见大约 6–10 cm。偏高表示很多力气用在跳，而不是往前。")
        case .gct:
            return ("跑姿", "触地时间", "单脚着地的毫秒数。休闲跑常见 220–300 ms。偏短更轻快，过长可能步态偏沉。")
        case .elev:
            return ("路线", "海拔", "路线高低变化。爬升会拖慢配速、拉高心率，所以单独放在跑姿后面看。")
        }
    }

    private static func advicePack(kind: MetricGuideKind,
                                   record: WorkoutRecord,
                                   detailed: WorkoutRecord,
                                   peerAvgPace: Double?) -> (facts: [MetricGuideFact], advice: String) {
        let dyn = detailed.runningMetrics
        switch kind {
        case .hr:
            let avg = detailed.avgHR ?? record.avgHR
            let maxHR = detailed.maxHR ?? record.maxHR
            var advice = "本场平均 \(fmtInt(avg))、峰值 \(fmtInt(maxHR))。"
            if let avg, let maxHR, maxHR > 0 {
                let ratio = avg / maxHR
                if ratio >= 0.9 {
                    advice += "平均已经很贴近峰值，整场偏拼。下次把配速放慢约 10–15 秒/公里，把平均心率压下来。"
                } else if avg >= 150 {
                    advice += "强度落在有氧偏上。若今天本想轻松跑，前半可以再收一点。"
                } else {
                    advice += "强度可控，峰值没有长时间顶死，适合作为稳态有氧。"
                }
            } else {
                advice += "结合区间一起看本场负担。"
            }
            return (
                [
                    MetricGuideFact(label: "平均", value: avg.map { "\(Int($0.rounded())) 次/分" } ?? "—"),
                    MetricGuideFact(label: "最高", value: maxHR.map { "\(Int($0.rounded())) 次/分" } ?? "—")
                ],
                advice
            )

        case .hrZone:
            let zones = detailed.hrZones
            let aero = zones.first { $0.index == 3 }?.fraction ?? 0
            let hard = zones.filter { $0.index >= 4 }.map(\.fraction).reduce(0, +)
            let aeroPct = Int((aero * 100).rounded())
            let hardPct = Int((hard * 100).rounded())
            let advice: String
            if aero >= 0.40 {
                advice = "有氧耐力占 \(aeroPct)%，主节奏对了。无氧和极限合计 \(hardPct)%，若这是轻松日，下次把上坡或前 1 公里再收一点。"
            } else {
                advice = "有氧占比偏低，这场更像节奏/间歇。如果目标是打底，把均速放慢，让更多时间留在有氧区。"
            }
            return (
                [
                    MetricGuideFact(label: "有氧耐力", value: "\(aeroPct)%"),
                    MetricGuideFact(label: "无氧+极限", value: "\(hardPct)%")
                ],
                advice
            )

        case .pace:
            let avg = record.avgPaceMinPerKM
            let best = detailed.bestPaceMinPerKM
            var advice = "平均 \(avg?.asPaceText ?? "—")，最快一公里 \(best?.asPaceText ?? "—")。"
            if let avg, let hist = peerAvgPace, hist > 0 {
                let d = (avg - hist) * 60
                if d <= -8 {
                    advice += "比近期同类平均快约 \(Int(abs(d).rounded())) 秒/公里，注意恢复。"
                } else if d >= 8 {
                    advice += "比近期同类平均慢约 \(Int(d.rounded())) 秒/公里，如果是轻松跑，这样刚好。"
                } else {
                    advice += "和近期同类配速接近，节奏稳定。"
                }
            } else if let avg, let best {
                advice += "前后差大约 \(Int(((avg - best) * 60).rounded())) 秒/公里，尽量避免第一公里冲太快。"
            }
            return (
                [
                    MetricGuideFact(label: "平均", value: avg.map { "\($0.asPaceText) /km" } ?? "—"),
                    MetricGuideFact(label: "最佳", value: best.map { "\($0.asPaceText) /km" } ?? "—")
                ],
                advice
            )

        case .paceZone:
            let zones = detailed.paceZones
            let steady = zones.first { $0.name == "稳态" }?.fraction ?? 0
            let burst = zones.filter { $0.name == "间歇" || $0.name == "冲刺" }.map(\.fraction).reduce(0, +)
            let steadyPct = Int((steady * 100).rounded())
            let burstPct = Int((burst * 100).rounded())
            let advice: String
            if steady >= 0.40 {
                advice = "稳态占了 \(steadyPct)%，巡航段成立。间歇和冲刺合计 \(burstPct)%，多半来自加速或下坡，不必特意再追配速。"
            } else if burst >= 0.25 {
                advice = "间歇和冲刺合计 \(burstPct)%，这场更像变速。如果目标是匀速有氧，把加速段收一收。"
            } else {
                advice = "稳态占比偏低，节奏偏散。下次试着把大部分时间压在均速附近。"
            }
            return (
                [
                    MetricGuideFact(label: "稳态", value: "\(steadyPct)%"),
                    MetricGuideFact(label: "冲刺+间歇", value: "\(burstPct)%")
                ],
                advice
            )

        case .split:
            let full = detailed.splits.filter { !$0.isPartial }
            let fast = full.map(\.paceMin).min()
            let slow = full.map(\.paceMin).max()
            let delta = (fast != nil && slow != nil) ? Int(((slow! - fast!) * 60).rounded()) : 0
            let advice: String
            if full.count < 2 {
                advice = "分段还不多，多跑几公里后再看最快最慢差更有参考。"
            } else if delta >= 25 {
                advice = "最快和最慢相差约 \(delta) 秒。常见是第一公里偏快、后程掉速。下次前 1–2 公里按均速再慢 5–8 秒出发。"
            } else {
                advice = "公里配速相差约 \(delta) 秒，节奏比较匀。保持这种「前面留一点」即可。"
            }
            return (
                [
                    MetricGuideFact(label: "最快公里", value: fast?.asPaceText ?? "—"),
                    MetricGuideFact(label: "最慢公里", value: slow?.asPaceText ?? "—")
                ],
                advice
            )

        case .stride:
            let avg = dyn.avgStrideM
            let maxV = dyn.maxStrideM
            let advice: String
            if let avg {
                if avg > 1.15 {
                    advice = "步幅 \(fmtM(avg)) 米偏大，容易变成刹车式着地。试着把步频提到 170 左右，步幅会自然收回。"
                } else if avg < 0.92 {
                    advice = "步幅 \(fmtM(avg)) 米偏碎。先把姿势站直、髋往前送，不必刻意跨大步。"
                } else {
                    advice = "步幅 \(fmtM(avg)) 米落在常见休闲跑区间，可以保持。想提速优先加步频。"
                }
            } else {
                advice = "本场没有步幅数据。需要 Apple Watch 跑步动态。"
            }
            return (
                [
                    MetricGuideFact(label: "平均", value: avg.map { "\(fmtM($0)) 米" } ?? "—"),
                    MetricGuideFact(label: "最大", value: maxV.map { "\(fmtM($0)) 米" } ?? "—")
                ],
                advice
            )

        case .cadence:
            let avg = dyn.avgCadence
            let maxV = dyn.maxCadence
            let advice: String
            if let avg {
                if avg < 160 {
                    advice = "步频 \(Int(avg.rounded())) 偏低。轻音乐或手表提示试着靠近 170，通常比拉大步幅更省膝盖。"
                } else if avg > 185 {
                    advice = "步频 \(Int(avg.rounded())) 已经很快。如果同时步幅很小，注意别碎步蹦；放松肩膀，让步幅自然打开一点。"
                } else {
                    advice = "步频 \(Int(avg.rounded())) 在舒适区间。配上现在的步幅，跑姿比较均衡。"
                }
            } else {
                advice = "本场没有步频数据。"
            }
            return (
                [
                    MetricGuideFact(label: "平均", value: avg.map { "\(Int($0.rounded())) 步/分" } ?? "—"),
                    MetricGuideFact(label: "最大", value: maxV.map { "\(Int($0.rounded())) 步/分" } ?? "—")
                ],
                advice
            )

        case .vo:
            let avg = dyn.avgVerticalOscCM
            let maxV = dyn.maxVerticalOscCM
            let advice: String
            if let avg {
                if avg >= 10 {
                    advice = "垂直振幅 \(fmtCM(avg)) cm 偏高，不少力气用在上下跳。想着「身体平着往前」，步频略提，起伏会下来。"
                } else {
                    advice = "垂直振幅 \(fmtCM(avg)) cm 还算平稳，前进效率不错。"
                }
            } else {
                advice = "本场没有垂直振幅数据。需要 Apple Watch 跑步动态。"
            }
            return (
                [
                    MetricGuideFact(label: "平均", value: avg.map { "\(fmtCM($0)) 厘米" } ?? "—"),
                    MetricGuideFact(label: "最大", value: maxV.map { "\(fmtCM($0)) 厘米" } ?? "—")
                ],
                advice
            )

        case .gct:
            let avg = dyn.avgGroundContactMS
            let maxV = dyn.maxGroundContactMS
            let advice: String
            if let avg {
                if avg > 280 {
                    advice = "触地 \(Int(avg.rounded())) ms 偏长，步态容易发沉。可把步频略提高，让脚更快离开地面。"
                } else {
                    advice = "触地 \(Int(avg.rounded())) ms 比较轻快。若后半这段变长，通常是配速掉了或上坡。"
                }
            } else {
                advice = "本场没有触地时间数据。需要 Apple Watch 跑步动态。"
            }
            return (
                [
                    MetricGuideFact(label: "平均", value: avg.map { "\(Int($0.rounded())) 毫秒" } ?? "—"),
                    MetricGuideFact(label: "最大", value: maxV.map { "\(Int($0.rounded())) 毫秒" } ?? "—")
                ],
                advice
            )

        case .elev:
            let alts = detailed.elevationSeries.map(\.meters)
            let hi = alts.max()
            let lo = alts.min()
            let climb = detailed.elevationGain ?? record.elevationGain ?? 0
            let advice: String
            if climb >= 80 {
                advice = "累计爬升 \(Int(climb.rounded())) 米，配速变慢、心率升高是正常的。看分段时以上坡那几公里为准，别跟平坦段比。"
            } else if climb <= 15 {
                advice = "几乎是平路，配速波动更多来自节奏而不是坡。想练匀速，这条路线合适。"
            } else {
                advice = "有一些起伏（爬升 \(Int(climb.rounded())) 米），后程心率偏高很常见，下坡再把步频稳住即可。"
            }
            return (
                [
                    MetricGuideFact(label: "最高", value: hi.map { "\(Int($0.rounded())) 米" } ?? "—"),
                    MetricGuideFact(label: "最低", value: lo.map { "\(Int($0.rounded())) 米" } ?? "—"),
                    MetricGuideFact(label: "累计爬升", value: "\(Int(climb.rounded())) 米")
                ],
                advice
            )
        }
    }

    private static func fmtInt(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private static func fmtM(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private static func fmtCM(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}

struct MetricGuideSheet: View {
    let content: MetricGuideContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(content.kicker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(content.title)
                        .font(.title2.bold())
                    Text(content.meaning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !content.facts.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(content.facts, id: \.label) { fact in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fact.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(fact.value)
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .minimumScaleFactor(0.8)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("结合本场")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        Text(content.advice)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") { dismiss() }
                }
            }
        }
    }
}

/// 心率 / 配速区间：名称、时长、独立进度条（不挤成一条堆叠色条）。
struct MetricListedZoneRow: View {
    let title: String
    var subtitle: String? = nil
    let trailing: String
    var caption: String? = nil
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(color)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 72, alignment: .trailing)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    if fraction > 0.002 {
                        Capsule()
                            .fill(color)
                            .frame(width: max(8, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                    } else {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

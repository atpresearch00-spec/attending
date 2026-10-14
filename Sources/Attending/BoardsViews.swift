import AppKit
import SwiftUI
import AttendingCore

/// Boards in the Study tab: the pinned exam's countdown, today's question-bank pace,
/// practice exams, the exam-day checklist and the other exams.
struct BoardsCard: View {
    @ObservedObject var exams: ExamStore
    var onShare: (BoardExam) -> Void
    /// Turns on exam week mode through the model, so its Focus shortcut runs.
    var turnOnExamWeek: (() -> Void)?
    @AppStorage("examWeek") private var examWeek = false
    @State private var editing: BoardExam?
    @State private var addingPractice = false

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Boards")
                    Spacer()
                    if let exam = exams.pinned { IconButton(symbol: "square.and.arrow.up", help: "Share a countdown card", size: 20) { onShare(exam) } }
                    IconButton(symbol: editing == nil ? "plus" : "xmark", help: editing == nil ? "Add an exam" : "Close", size: 20) {
                        editing = editing == nil ? BoardExam(kind: .comlex1, date: Calendar.current.date(byAdding: .month, value: 2, to: Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!)!) : nil
                    }
                }
                if let exam = editing {
                    ExamEditor(exam: exam, isNew: !exams.exams.contains { $0.id == exam.id },
                               onSave: { exams.save($0); editing = nil },
                               onDelete: { exams.remove($0); editing = nil })
                } else if let exam = exams.pinned, exams.visible(exam) {
                    hero(exam)
                    bank(exam)
                    practice(exam)
                    if BoardsMath.calendarDays(from: Date(), to: exam.date) <= 7 {
                        if !examWeek, let turnOnExamWeek {
                            HStack {
                                Text("Final week. Turn on exam week mode for a quieter notch?").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                Spacer()
                                PillButton(title: "Turn on", symbol: "moon.fill", tint: Theme.attention, action: turnOnExamWeek)
                            }
                        }
                        checklist(exam)
                    }
                    others(except: exam)
                } else if let exam = exams.pinned {
                    Text("\(exam.name) is more than 30 days out. Calm mode keeps the countdown hidden until then.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    Button("Edit") { editing = exam }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                } else {
                    Text("Add COMLEX, USMLE, shelf or block exams for a countdown, a daily question pace and practice-exam tracking.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Pieces

    private func hero(_ exam: BoardExam) -> some View {
        Button { editing = exam } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let (value, label) = exams.countdown(exam, now: context.date)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(exams.urgency(exam))
                            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        }
                    }
                    Text(exam.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(exam.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        Text("·")
                        Text(BoardsMath.phase(for: exam, now: Date()).title)
                        if let target = exam.targetScore, !exam.kind.passFail { Text("· goal \(target)") }
                    }.font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let progress = BoardsMath.dedicatedProgress(for: exam, now: Date()) {
                    ZStack {
                        Circle().stroke(Theme.raised, lineWidth: 5)
                        Circle().trim(from: 0, to: progress).stroke(exams.urgency(exam), style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("\(Int(progress * 100))%").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 46, height: 46)
                    .help("\(Int(progress * 100))% of dedicated has passed")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit \(exam.name)")
    }

    @ViewBuilder private func bank(_ exam: BoardExam) -> some View {
        if let total = exam.bankTotal, total > 0 {
            let today = exams.questionsToday(exam)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(exam.bankName.isEmpty ? "Questions" : exam.bankName).font(.system(size: 12, weight: .semibold))
                    if let target = today.target {
                        Text(target == 0 ? "· bank finished" : "· \(today.done) / \(target) today")
                            .font(.system(size: 11)).foregroundStyle(target > 0 && today.done >= target ? Theme.done : Theme.secondary)
                    }
                    Spacer()
                    ForEach([-1, 1, 10, 40], id: \.self) { step in
                        Button(step > 0 ? "+\(step)" : "−1") { exams.logQuestions(step, for: exam) }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(Capsule().fill(Theme.raised))
                            .help(step > 0 ? "Log \(step) question\(step == 1 ? "" : "s")" : "Undo one")
                    }
                }
                ProgressView(value: Double(exam.bankDone), total: Double(total)).tint(Theme.done).controlSize(.small)
                Text("\(exam.bankDone.formatted()) of \(total.formatted()) done · \((exam.bankLeft ?? 0).formatted()) left")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder private func practice(_ exam: BoardExam) -> some View {
        let scored = exam.scoredPractice
        if addingPractice {
            PracticeEditor { item in var updated = exam; updated.practice.append(item); exams.save(updated); addingPractice = false } onCancel: { addingPractice = false }
        } else if !exam.practice.isEmpty || exam.kind.isBoard {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                if let next = exam.nextPractice {
                    let days = BoardsMath.calendarDays(from: Date(), to: next.date)
                    Text("\(next.name) \(days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days")").font(.system(size: 11, weight: .medium)).lineLimit(1)
                } else if let last = scored.last, let score = last.score {
                    Text("\(last.name): \(score)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                } else {
                    Text("Practice exams").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                if scored.count >= 2 { Sparkline(values: scored.compactMap(\.score).map(Double.init)).frame(width: 60, height: 16) }
                Spacer()
                Button { addingPractice = true } label: { Image(systemName: "plus.circle").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Add a practice exam or score")
            }
            .contextMenu {
                ForEach(exam.practice.sorted { $0.date < $1.date }) { item in
                    Button("Remove \(item.name)\(item.score.map { " (\($0))" } ?? "")") { var updated = exam; updated.practice.removeAll { $0.id == item.id }; exams.save(updated) }
                }
            }
        }
    }

    private func checklist(_ exam: BoardExam) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Exam-day checklist").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            ForEach(ExamStore.checklist, id: \.self) { item in
                Button { exams.toggleChecklist(item, for: exam) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: exam.checklistDone.contains(item) ? "checkmark.square.fill" : "square").foregroundStyle(exam.checklistDone.contains(item) ? Theme.done : Theme.tertiary)
                        Text(item).font(.system(size: 11)).strikethrough(exam.checklistDone.contains(item), color: Theme.tertiary)
                            .foregroundStyle(exam.checklistDone.contains(item) ? Theme.tertiary : Theme.primary)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func others(except pinned: BoardExam) -> some View {
        let rest = exams.upcoming.filter { $0.id != pinned.id }
        if !rest.isEmpty {
            Divider().opacity(0.3)
            ForEach(rest.prefix(3)) { exam in
                HStack {
                    Button { editing = exam } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(exam.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(exam.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Text(exams.compact(exam)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(exams.urgency(exam))
                }
                .contextMenu { Button("Pin to the notch and Home") { exams.pinnedID = exam.id } }
            }
        }
    }
}

/// Add or edit an exam.
struct ExamEditor: View {
    @State var exam: BoardExam
    let isNew: Bool
    var onSave: (BoardExam) -> Void
    var onDelete: (BoardExam) -> Void
    @State private var dedicated = false
    @State private var bank = false
    @State private var releaseSet = false
    private let weekdays = [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Exam", selection: $exam.kind) { ForEach(BoardExam.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
            if !exam.kind.isBoard {
                TextField(exam.kind == .shelf ? "e.g. Internal Medicine COMAT" : "e.g. Exam 2", text: $exam.customName).textFieldStyle(.roundedBorder)
            }
            DatePicker("Starts", selection: $exam.date, displayedComponents: [.date, .hourAndMinute])
            Toggle("Dedicated study period", isOn: $dedicated)
            if dedicated {
                DatePicker("Dedicated starts", selection: Binding(get: { exam.dedicatedStart ?? Calendar.current.date(byAdding: .weekOfYear, value: -6, to: exam.date)! }, set: { exam.dedicatedStart = $0 }), displayedComponents: .date)
            }
            HStack(spacing: 4) {
                Text("Days off").font(.system(size: 12))
                Spacer()
                ForEach(weekdays, id: \.0) { day, letter in
                    Button(letter) { if exam.daysOff.contains(day) { exam.daysOff.remove(day) } else { exam.daysOff.insert(day) } }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(exam.daysOff.contains(day) ? Theme.attention.opacity(0.25) : Theme.raised))
                        .foregroundStyle(exam.daysOff.contains(day) ? Theme.attention : Theme.secondary)
                        .help(exam.daysOff.contains(day) ? "Study day" : "Day off")
                }
            }
            if !exam.kind.passFail {
                HStack { Text("Target score"); Spacer(); TextField("optional", value: $exam.targetScore, format: .number).textFieldStyle(.roundedBorder).frame(width: 90) }
            } else {
                Text("\(exam.kind.short) is pass/fail, so there's no target score.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            Toggle("Question bank pace", isOn: $bank)
            if bank {
                HStack {
                    TextField("UWorld", text: $exam.bankName).textFieldStyle(.roundedBorder)
                    TextField("total", value: $exam.bankTotal, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                    TextField("done", value: $exam.bankDone, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            if exam.kind.typicalScoreDays != nil {
                Toggle("Score release date", isOn: $releaseSet)
                if releaseSet {
                    DatePicker("Scores out", selection: Binding(get: { exam.scoreRelease ?? exam.expectedScores ?? exam.date }, set: { exam.scoreRelease = $0 }), displayedComponents: .date)
                }
            }
            HStack {
                PillButton(title: isNew ? "Add exam" : "Save", symbol: "checkmark", tint: Theme.done, prominent: true) {
                    if !dedicated { exam.dedicatedStart = nil }
                    if !bank { exam.bankTotal = nil }
                    if !releaseSet { exam.scoreRelease = nil }
                    if exam.kind.passFail { exam.targetScore = nil }
                    onSave(exam)
                }
                Spacer()
                if !isNew { Button("Delete", role: .destructive) { onDelete(exam) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.failed) }
            }
        }
        .font(.system(size: 12))
        .onAppear { dedicated = exam.dedicatedStart != nil; bank = exam.bankTotal != nil; releaseSet = exam.scoreRelease != nil }
    }
}

/// A practice exam: a date to count down to, and a score once it's taken.
struct PracticeEditor: View {
    var onAdd: (BoardExam.Practice) -> Void
    var onCancel: () -> Void
    @State private var name = ""
    @State private var date = Date()
    @State private var score: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("NBME 30, COMSAE, UWSA 1", text: $name).textFieldStyle(.roundedBorder)
                TextField("score", value: $score, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
            }
            DatePicker("Date", selection: $date, displayedComponents: .date).font(.system(size: 12))
            HStack {
                PillButton(title: "Add", symbol: "plus", tint: Theme.done, prominent: true) { onAdd(.init(name: name.isEmpty ? "Practice exam" : name, date: date, score: score)) }
                Button("Cancel", action: onCancel).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let low = values.min() ?? 0, high = max((values.max() ?? 1), low + 1)
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: geo.size.width * CGFloat(index) / CGFloat(max(1, values.count - 1)), y: geo.size.height * (1 - CGFloat((value - low) / (high - low))))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(Theme.done, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The countdown as a card for stories and group chats.
struct BoardsShareCard: View {
    let exam: BoardExam
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope").font(.system(size: 34, weight: .semibold))
                Text("Attending").font(.system(size: 34, weight: .semibold))
                Spacer()
            }.foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(exam.name).font(.system(size: 60, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(value).font(.system(size: 280, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 60, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }.foregroundStyle(.white)
            if let total = exam.bankTotal, total > 0 {
                Text("\(exam.bankDone.formatted()) \(exam.bankName.isEmpty ? "questions" : exam.bankName + " questions") done").font(.system(size: 42, weight: .medium)).foregroundStyle(.white.opacity(0.7)).padding(.top, 10)
            }
            Spacer()
            Text(exam.date.formatted(date: .long, time: .omitted)).font(.system(size: 38)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(80)
        .frame(width: 1080, height: 1350)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.1), Color(red: 0.02, green: 0.02, blue: 0.03)], startPoint: .top, endPoint: .bottom))
    }

    /// Renders the card to a PNG in ~/Pictures/Attending and returns its location.
    @MainActor static func render(_ exam: BoardExam, value: String, label: String) -> URL? {
        let renderer = ImageRenderer(content: BoardsShareCard(exam: exam, value: value, label: label))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Attending", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(exam.shortName) countdown \(Date().formatted(.iso8601.year().month().day())).png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return file
    }
}

/// A short burst of confetti, for finishing an exam.
struct ConfettiView: View {
    @State private var start = Date()
    private let pieces: [(x: Double, speed: Double, spin: Double, color: Color, delay: Double)] = (0..<36).map { _ in
        (Double.random(in: 0...1), Double.random(in: 60...140), Double.random(in: -4...4), [Theme.done, Theme.attention, Theme.working, .pink, .white].randomElement()!, Double.random(in: 0...0.6))
    }
    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSince(start)
                for piece in pieces where t > piece.delay {
                    let age = t - piece.delay
                    let y = -10 + age * piece.speed
                    guard y < size.height + 10 else { continue }
                    var rect = canvas
                    rect.translateBy(x: piece.x * size.width + sin(age * 3 + piece.spin) * 8, y: y)
                    rect.rotate(by: .radians(age * piece.spin))
                    rect.fill(Path(CGRect(x: -3, y: -1.5, width: 6, height: 3)), with: .color(piece.color.opacity(max(0, 1 - age / 3))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Block and shelf scores over the year, with the trend, next to the boards countdown.
struct ScoresCard: View {
    @ObservedObject var exams: ExamStore
    @State private var adding = false
    @State private var name = ""
    @State private var date = Date()
    @State private var score: Double?
    @State private var kind = BoardExam.Kind.block

    var body: some View {
        let past = exams.past
        let percents = past.filter(\.resultIsPercent).compactMap(\.result).reversed().map { $0 }
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Scores")
                    if percents.count >= 2 { Sparkline(values: percents).frame(width: 70, height: 16) }
                    if !percents.isEmpty {
                        Text("avg \(Int((percents.reduce(0, +) / Double(percents.count)).rounded()))%").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    IconButton(symbol: adding ? "xmark" : "plus", help: adding ? "Cancel" : "Log an exam score", size: 20) { adding.toggle() }
                }
                if adding {
                    HStack {
                        Picker("", selection: $kind) { ForEach([BoardExam.Kind.block, .shelf, .custom], id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 110)
                        TextField("Exam 2", text: $name).textFieldStyle(.roundedBorder)
                        TextField("%", value: $score, format: .number).textFieldStyle(.roundedBorder).frame(width: 56)
                    }
                    HStack {
                        DatePicker("Taken", selection: $date, displayedComponents: .date).font(.system(size: 12))
                        Spacer()
                        PillButton(title: "Save", symbol: "checkmark", tint: Theme.done, prominent: true) {
                            guard let score else { return }
                            exams.logPast(kind: kind, name: name.isEmpty ? "Exam" : name, date: date, result: score)
                            name = ""; self.score = nil; adding = false
                        }.disabled(score == nil)
                    }
                }
                if past.isEmpty && !adding {
                    Text("Log block and shelf scores to see your trend through the year. Finished exams show up here to fill in.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(past.prefix(6)) { exam in ScoreRow(exams: exams, exam: exam) }
            }
        }
    }
}

private struct ScoreRow: View {
    @ObservedObject var exams: ExamStore
    let exam: BoardExam
    @State private var entry: Double?
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(exam.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(exam.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if let text = exam.resultText {
                Text(text).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(exam.resultIsPercent ? ((exam.result ?? 0) >= 80 ? Theme.done : (exam.result ?? 0) >= 70 ? Theme.primary : Theme.attention) : Theme.primary)
            } else {
                TextField(exam.resultIsPercent ? "%" : "score", value: $entry, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
                    .onSubmit { if let entry { exams.setResult(entry, for: exam) } }
            }
        }
        .contextMenu {
            if exam.result != nil { Button("Clear score") { exams.setResult(nil, for: exam) } }
            Button("Remove exam") { exams.remove(exam) }
        }
    }
}

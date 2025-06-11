import SwiftUI
import SwiftData

// MARK: - Model

enum TimePrecision: Int, Codable, CaseIterable {
    case day = 0, time = 1
    var description: String { switch self { case .day: return "Date Only"; case .time: return "Date & Time" } }
}

@Model
final class Event {
    var startDate: Date
    var endDate: Date?
    var title: String
    var details: String
    var precision: TimePrecision

    init(startDate: Date, endDate: Date? = nil, title: String, details: String, precision: TimePrecision = .day) {
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.details = details
        self.precision = precision
    }
    
    var duration: TimeInterval {
        guard let endDate else { return 0 }
        return endDate.timeIntervalSince(startDate)
    }
    
    var effectiveInterval: DateInterval {
        DateInterval(start: startDate, duration: max(3600, duration))
    }
}

// MARK: - Main View

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Event.startDate) private var events: [Event]

    @State private var isShowingAddEventSheet = false
    @State private var eventToEdit: Event?

    var body: some View {
        NavigationView {
            Group {
                if events.isEmpty {
                    ContentUnavailableView("No Events Yet", systemImage: "calendar.badge.plus", description: Text("Tap the + button to add your first event."))
                } else {
                    GeometryReader { geometry in
                        TimelineView(
                            events: events,
                            eventToEdit: $eventToEdit,
                            visibleSize: geometry.size
                        )
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { isShowingAddEventSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .sheet(isPresented: $isShowingAddEventSheet) { AddEventView(event: nil) }
            .sheet(item: $eventToEdit) { event in AddEventView(event: event) }
        }
    }
}

// MARK: - Proportional Timeline Components

struct LayoutEvent: Identifiable {
    let event: Event
    var frame: CGRect
    var id: ObjectIdentifier { event.id }
}

struct TimelineView: View {
    let events: [Event]
    @Binding var eventToEdit: Event?
    let visibleSize: CGSize
    
    @State private var zoomScale: CGFloat = 1.0
    @State private var initialZoomScale: CGFloat? = nil
    @State private var hasAppeared = false

    private var timelineBounds: (start: Date, end: Date)? {
        guard let firstEvent = events.first,
              let lastEvent = events.max(by: { ($0.endDate ?? $0.startDate) < ($1.endDate ?? $1.startDate) })
        else { return nil }
        
        let calendar = Calendar.current
        // The bounds now start at the beginning of the first event's day.
        let startOfDay = calendar.startOfDay(for: firstEvent.startDate)
        // And end at the beginning of the day *after* the last event ends.
        let endOfLastDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastEvent.endDate ?? lastEvent.startDate)) ?? (lastEvent.endDate ?? lastEvent.startDate)

        return (startOfDay, endOfLastDay)
    }
    
    var body: some View {
        if let bounds = timelineBounds {
            let metrics = createMetrics(for: visibleSize, bounds: bounds)
            let layouts = generateLayouts(for: events, metrics: metrics, containerWidth: visibleSize.width)
            
            ScrollView {
                ZStack(alignment: .topLeading) {
                    TimelineBackgroundView(metrics: metrics)
                    
                    ForEach(layouts) { layout in
                        EventContentView(event: layout.event)
                            .frame(width: layout.frame.width, height: layout.frame.height)
                            .offset(x: layout.frame.minX, y: layout.frame.minY)
                            .onTapGesture { eventToEdit = layout.event }
                    }
                }
                .frame(width: visibleSize.width, height: metrics.totalHeight)
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if initialZoomScale == nil { initialZoomScale = zoomScale }
                        zoomScale = max(0.1, (initialZoomScale ?? 1.0) * value)
                    }
                    .onEnded { _ in initialZoomScale = nil }
            )
            .onAppear {
                if !hasAppeared {
                    let contentHeightAtScaleOne = createMetrics(for: visibleSize, bounds: bounds, scale: 1.0).totalHeight
                    if contentHeightAtScaleOne > visibleSize.height {
                        zoomScale = visibleSize.height / contentHeightAtScaleOne
                    }
                    hasAppeared = true
                }
            }
        }
    }
    
    private func createMetrics(for size: CGSize, bounds: (start: Date, end: Date), scale: CGFloat? = nil) -> TimelineMetrics {
        let currentScale = scale ?? zoomScale
        return TimelineMetrics(bounds: bounds, scale: currentScale)
    }

    private func generateLayouts(for events: [Event], metrics: TimelineMetrics, containerWidth: CGFloat) -> [LayoutEvent] {
        var eventLanes: [ObjectIdentifier: Int] = [:]
        var laneIntervals: [Int: [DateInterval]] = [:]
        
        for event in events {
            let eventInterval = event.effectiveInterval
            var currentLane = 0
            while true {
                if let intervalsInLane = laneIntervals[currentLane], intervalsInLane.contains(where: { $0.intersects(eventInterval) }) {
                    currentLane += 1
                } else {
                    eventLanes[event.id] = currentLane
                    laneIntervals[currentLane, default: []].append(eventInterval)
                    break
                }
            }
        }

        let totalLanes = (laneIntervals.keys.max() ?? 0) + 1
        let axisWidth: CGFloat = 60
        let contentWidth = containerWidth - axisWidth
        let laneWidth = totalLanes > 0 ? contentWidth / CGFloat(totalLanes) : contentWidth
        
        var layouts: [LayoutEvent] = []
        for event in events {
            if let laneIndex = eventLanes[event.id] {
                let y = metrics.yPosition(for: event.startDate)
                let height = metrics.height(for: event.effectiveInterval.duration)
                let x = axisWidth + (CGFloat(laneIndex) * laneWidth)
                let frame = CGRect(x: x, y: y, width: laneWidth - 5, height: height)
                layouts.append(LayoutEvent(event: event, frame: frame))
            }
        }
        return layouts
    }
}

struct TimelineMetrics {
    let bounds: (start: Date, end: Date)
    let totalHeight: CGFloat
    let pointsPerSecond: CGFloat
    
    init(bounds: (start: Date, end: Date), scale: CGFloat) {
        self.bounds = bounds
        let pointsPerHour: CGFloat = 120.0 * scale
        self.pointsPerSecond = pointsPerHour / 3600
        
        let totalDuration = bounds.end.timeIntervalSince(bounds.start)
        self.totalHeight = totalDuration * self.pointsPerSecond
    }
    
    func yPosition(for date: Date) -> CGFloat {
        date.timeIntervalSince(bounds.start) * pointsPerSecond
    }
    
    func height(for duration: TimeInterval) -> CGFloat {
        max(duration * pointsPerSecond, 44)
    }
}

struct TimelineBackgroundView: View {
    let metrics: TimelineMetrics
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 50, y: 0))
                path.addLine(to: CGPoint(x: 50, y: metrics.totalHeight))
            }.stroke(.tertiary, lineWidth: 1)
            
            ForEach(getMajorDateMarkers(), id: \.self) { date in
                let yPos = metrics.yPosition(for: date)
                Path { path in
                    path.move(to: CGPoint(x: 45, y: yPos))
                    path.addLine(to: CGPoint(x: 55, y: yPos))
                }.stroke(.tertiary, lineWidth: 1)
                
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
                    .offset(x: 0, y: yPos - 8)
            }
        }
    }
    
    private func getMajorDateMarkers() -> [Date] {
        var dates: [Date] = []
        let calendar = Calendar.current
        var currentDate = metrics.bounds.start
        
        while currentDate <= metrics.bounds.end {
            dates.append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }
        return dates
    }
}

struct EventContentView: View {
    let event: Event
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title).font(.system(size: 14, weight: .bold)).lineLimit(1)
            Text(dateString()).font(.caption).foregroundColor(.secondary).lineLimit(2)
            Text(event.details).font(.caption).foregroundColor(.secondary).padding(.top, 1)
            Spacer(minLength: 0)
        }
        .padding(8).background(Color(.secondarySystemBackground)).cornerRadius(8).clipped()
    }
    
    private func dateString() -> String {
        let dateFormat = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        let timeFormat = Date.FormatStyle.dateTime.hour().minute()

        if let endDate = event.endDate {
            let startString: String
            let endString: String
            
            if event.precision == .time {
                startString = event.startDate.formatted(dateFormat) + ", " + event.startDate.formatted(timeFormat)
                if Calendar.current.isDate(event.startDate, inSameDayAs: endDate) {
                    endString = endDate.formatted(timeFormat)
                } else {
                    endString = endDate.formatted(dateFormat) + ", " + endDate.formatted(timeFormat)
                }
            } else {
                startString = event.startDate.formatted(dateFormat)
                endString = endDate.formatted(dateFormat)
            }
            return startString == endString ? startString : "\(startString) – \(endString)"

        } else {
            return event.precision == .time ?
                "\(event.startDate.formatted(dateFormat)), \(event.startDate.formatted(timeFormat))" :
                event.startDate.formatted(dateFormat)
        }
    }
}

// MARK: - Add/Edit Event View

struct AddEventView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss
    let event: Event?

    @State private var title: String = ""
    @State private var details: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date().addingTimeInterval(3600)
    @State private var precision: TimePrecision = .day
    @State private var isIntervalEvent: Bool = false
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Title", text: $title)
                    Toggle("Interval Event", isOn: $isIntervalEvent)
                }

                Section(header: Text(isIntervalEvent ? "Start" : "Date & Time")) {
                    Picker("Precision", selection: $precision) {
                        ForEach(TimePrecision.allCases, id: \.self) { p in Text(p.description).tag(p) }
                    }.pickerStyle(.segmented)
                    DateTimeRow(title: "Date", date: $startDate, precision: precision)
                }

                if isIntervalEvent {
                    Section(header: Text("End")) { DateTimeRow(title: "Date", date: $endDate, precision: precision) }
                }
                
                Section(header: Text("Description")) {
                    TextEditor(text: $details).frame(minHeight: 150)
                }
            }
            .navigationTitle(event == nil ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { save(); dismiss() }.disabled(title.isEmpty) }
            }
            .onAppear(perform: setupInitialState)
            .onChange(of: isIntervalEvent) { if !$1 { endDate = startDate.addingTimeInterval(3600) } }
            .onChange(of: startDate) { if endDate < $1 { endDate = $1.addingTimeInterval(3600) } }
        }
    }
    
    private func setupInitialState() {
        if let event {
            title = event.title; details = event.details; startDate = event.startDate; precision = event.precision
            if let eventEndDate = event.endDate { isIntervalEvent = true; endDate = eventEndDate } else { isIntervalEvent = false }
        }
    }
    
    private func save() {
        var finalStartDate = startDate; var finalEndDate: Date? = isIntervalEvent ? endDate : nil
        if precision == .day {
            finalStartDate = Calendar.current.startOfDay(for: startDate)
            if let unwrappedEndDate = finalEndDate { finalEndDate = Calendar.current.startOfDay(for: unwrappedEndDate) }
        }
        
        if let event {
            event.title = title; details = details; event.startDate = finalStartDate; event.endDate = finalEndDate; event.precision = precision
        } else {
            modelContext.insert(Event(startDate: finalStartDate, endDate: finalEndDate, title: title, details: details, precision: precision))
        }
    }
}

struct DateTimeRow: View {
    let title: String; @Binding var date: Date; let precision: TimePrecision
    var body: some View {
        HStack {
            Text(title).frame(width: 50, alignment: .leading)
            DatePicker(title, selection: $date, displayedComponents: .date).labelsHidden()
            if precision == .time { DatePicker(title, selection: $date, displayedComponents: [.hourAndMinute]).labelsHidden() }
        }
    }
}

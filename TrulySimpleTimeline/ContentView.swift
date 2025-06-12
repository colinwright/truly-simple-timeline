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

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

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
    
    @State private var isDragging: Bool = false
    @State private var draggingEventID: ObjectIdentifier?
    @State private var dragOffset: CGSize = .zero
    @State private var dropIndicatorDate: Date?
    
    @State private var scrollPosition: CGFloat = 0
    
    private let maxZoomScale: CGFloat = 100.0

    private var timelineBounds: (start: Date, end: Date)? {
        guard let firstEvent = events.first,
              let lastEvent = events.max(by: { ($0.endDate ?? $0.startDate) < ($1.endDate ?? $1.startDate) })
        else { return nil }
        
        let firstDate = firstEvent.startDate
        let lastDate = lastEvent.endDate ?? lastEvent.startDate
        
        let totalEventDuration = max(86400 * 30, lastDate.timeIntervalSince(firstDate))
        let buffer = totalEventDuration * 0.5

        let bufferedStart = firstDate.addingTimeInterval(-buffer)
        let bufferedEnd = lastDate.addingTimeInterval(buffer)

        return (bufferedStart, bufferedEnd)
    }
    
    private var minZoomScale: CGFloat {
        guard let bounds = timelineBounds else { return 0.1 }
        let contentHeightAtScaleOne = TimelineMetrics(bounds: bounds).height(for: bounds.end.timeIntervalSince(bounds.start), at: 1.0)
        if contentHeightAtScaleOne > visibleSize.height {
            return visibleSize.height / contentHeightAtScaleOne
        }
        return 1.0
    }
    
    var body: some View {
        if let bounds = timelineBounds {
            let metrics = TimelineMetrics(bounds: bounds)
            let totalHeight = metrics.yPosition(for: bounds.end, at: zoomScale) - metrics.yPosition(for: bounds.start, at: zoomScale)
            
            let visibleYRange = -scrollPosition ... -scrollPosition + visibleSize.height
            let visibleDateInterval = DateInterval(
                start: metrics.date(at: visibleYRange.lowerBound, for: zoomScale),
                end: metrics.date(at: visibleYRange.upperBound, for: zoomScale)
            )
            
            let screenDuration = visibleDateInterval.duration
            let bufferedDateInterval = DateInterval(
                start: visibleDateInterval.start.addingTimeInterval(-screenDuration),
                end: visibleDateInterval.end.addingTimeInterval(screenDuration)
            )
            
            let virtualizedEvents = events.filter { $0.effectiveInterval.intersects(bufferedDateInterval) }
            let layouts = generateLayouts(for: virtualizedEvents, metrics: metrics, containerWidth: visibleSize.width, at: zoomScale)
            
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).minY)
                        }
                        
                        TimelineBackgroundView(metrics: metrics, zoomScale: zoomScale, visibleDateInterval: visibleDateInterval)
                        
                        if let dropDate = dropIndicatorDate, isDragging {
                            let yPos = metrics.yPosition(for: dropDate, at: zoomScale)
                            
                            Path { path in
                                path.move(to: CGPoint(x: 45, y: yPos))
                                path.addLine(to: CGPoint(x: 55, y: yPos))
                            }.stroke(Color.accentColor, lineWidth: 2)
                            
                            Text(dropDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                                .background(Color.accentColor).foregroundColor(Color(.systemBackground)).clipShape(Capsule())
                                .offset(x: 65, y: yPos - 12).zIndex(2)
                        }
                        
                        ForEach(layouts) { layout in
                            let isBeingDragged = draggingEventID == layout.event.id
                            
                            EventContentView(event: layout.event)
                                .frame(width: layout.frame.width, height: layout.frame.height)
                                .offset(x: layout.frame.minX, y: layout.frame.minY)
                                .scaleEffect(isBeingDragged ? 1.05 : 1.0).opacity(isBeingDragged ? 0.75 : 1.0)
                                .offset(isBeingDragged ? dragOffset : .zero).zIndex(isBeingDragged ? 1 : 0)
                                .onTapGesture { if !isDragging { eventToEdit = layout.event } }
                                .gesture(
                                    LongPressGesture(minimumDuration: 0.25)
                                        .onEnded { _ in
                                            isDragging = true
                                            draggingEventID = layout.event.id
                                            let haptics = UIImpactFeedbackGenerator(style: .medium)
                                            haptics.impactOccurred()
                                        }
                                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("scroll"))
                                            .onChanged { value in
                                                if isDragging {
                                                    dragOffset = value.translation
                                                    updateDropIndicator(event: layout.event, dragTranslation: value.translation, metrics: metrics, at: zoomScale)
                                                }
                                            }
                                            .onEnded { value in
                                                guard let eventToMove = events.first(where: { $0.id == draggingEventID }) else {
                                                    resetDragState(); return
                                                }

                                                let dateAtCenter = metrics.date(at: -scrollPosition + (visibleSize.height / 2), for: zoomScale)
                                                let finalDragTranslation = value.translation
                                                
                                                resetDragState()

                                                DispatchQueue.main.async {
                                                    updateEventPosition(event: eventToMove, dragTranslation: finalDragTranslation, metrics: metrics, at: zoomScale)
                                                    
                                                    DispatchQueue.main.async {
                                                        if let newBounds = timelineBounds {
                                                            let newMetrics = TimelineMetrics(bounds: newBounds)
                                                            let newY = newMetrics.yPosition(for: dateAtCenter, at: zoomScale)
                                                            let newScrollOffset = newY - (visibleSize.height / 2)
                                                            proxy.scrollTo("timeline_content", anchor: UnitPoint(x: 0, y: newScrollOffset / (newMetrics.yPosition(for: newBounds.end, at: zoomScale) - newMetrics.yPosition(for: newBounds.start, at: zoomScale))))
                                                        }
                                                    }
                                                }
                                            }
                                        )
                                )
                        }
                    }
                    .frame(width: visibleSize.width, height: totalHeight).id("timeline_content")
                }
                .scrollDisabled(isDragging).coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in self.scrollPosition = value }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            guard !isDragging else { return }
                            if initialZoomScale == nil { initialZoomScale = zoomScale }
                            
                            let dateAtCenter = metrics.date(at: -scrollPosition + (visibleSize.height / 2), for: zoomScale)
                            if let initial = initialZoomScale { zoomScale = max(minZoomScale, min(maxZoomScale, initial * value)) }
                            
                            let newY = metrics.yPosition(for: dateAtCenter, at: zoomScale)
                            let newScrollOffset = newY - (visibleSize.height / 2)
                            proxy.scrollTo("timeline_content", anchor: UnitPoint(x: 0, y: newScrollOffset / totalHeight))
                        }
                        .onEnded { _ in initialZoomScale = nil }
                )
                .onAppear {
                    DispatchQueue.main.async {
                        zoomScale = minZoomScale
                        let firstEventY = metrics.yPosition(for: bounds.start, at: minZoomScale)
                        let scrollTargetY = firstEventY - (visibleSize.height * 0.1)
                        proxy.scrollTo("timeline_content", anchor: UnitPoint(x: 0, y: scrollTargetY / totalHeight))
                    }
                }
            }
        }
    }
    
    private func resetDragState() { isDragging = false; draggingEventID = nil; dragOffset = .zero; dropIndicatorDate = nil }
    
    private func updateEventPosition(event: Event, dragTranslation: CGSize, metrics: TimelineMetrics, at zoomScale: CGFloat) {
        let eventDuration = event.effectiveInterval.duration
        let timeOffset = dragTranslation.height / metrics.pointsPerSecond(at: zoomScale)
        let newStartDate = event.startDate.addingTimeInterval(timeOffset)
        
        event.startDate = newStartDate
        if event.endDate != nil { event.endDate = newStartDate.addingTimeInterval(eventDuration) }
    }
    
    private func updateDropIndicator(event: Event, dragTranslation: CGSize, metrics: TimelineMetrics, at zoomScale: CGFloat) {
        let timeOffset = dragTranslation.height / metrics.pointsPerSecond(at: zoomScale)
        dropIndicatorDate = event.startDate.addingTimeInterval(timeOffset)
    }
    
    private func generateLayouts(for events: [Event], metrics: TimelineMetrics, containerWidth: CGFloat, at zoomScale: CGFloat) -> [LayoutEvent] {
        var eventLanes: [ObjectIdentifier: Int] = [:]; var laneIntervals: [Int: [DateInterval]] = [:]
        for event in events {
            let eventInterval = event.effectiveInterval
            var currentLane = 0
            while true {
                if let intervalsInLane = laneIntervals[currentLane],
                   intervalsInLane.contains(where: { $0.intersects(eventInterval) || $0.end == eventInterval.start }) {
                    currentLane += 1
                } else {
                    eventLanes[event.id] = currentLane; laneIntervals[currentLane, default: []].append(eventInterval); break
                }
            }
        }

        let axisWidth: CGFloat = 60; let totalLanes = (laneIntervals.keys.max() ?? 0) + 1
        let contentWidth = containerWidth - axisWidth; let laneWidth = totalLanes > 0 ? contentWidth / CGFloat(totalLanes) : contentWidth
        var layouts: [LayoutEvent] = []
        for event in events {
            if let laneIndex = eventLanes[event.id] {
                let y = metrics.yPosition(for: event.startDate, at: zoomScale)
                let height = metrics.height(for: event.effectiveInterval.duration, at: zoomScale)
                let x = axisWidth + (CGFloat(laneIndex) * laneWidth)
                layouts.append(LayoutEvent(event: event, frame: CGRect(x: x, y: y, width: laneWidth - 5, height: height)))
            }
        }
        return layouts
    }
}


struct TimelineMetrics {
    let bounds: (start: Date, end: Date)
    
    func pointsPerSecond(at zoomScale: CGFloat) -> CGFloat { (120.0 * zoomScale) / 3600 }
    func yPosition(for date: Date, at zoomScale: CGFloat) -> CGFloat { (date.timeIntervalSince(bounds.start)) * pointsPerSecond(at: zoomScale) }
    func date(at yPosition: CGFloat, for zoomScale: CGFloat) -> Date { bounds.start.addingTimeInterval(yPosition / pointsPerSecond(at: zoomScale)) }
    func height(for duration: TimeInterval, at zoomScale: CGFloat) -> CGFloat { max(duration * pointsPerSecond(at: zoomScale), 44) }
}

struct TimelineBackgroundView: View {
    let metrics: TimelineMetrics
    let zoomScale: CGFloat
    let visibleDateInterval: DateInterval
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                let yStart = metrics.yPosition(for: visibleDateInterval.start, at: zoomScale) - 100
                let yEnd = metrics.yPosition(for: visibleDateInterval.end, at: zoomScale) + 100
                path.move(to: CGPoint(x: 50, y: yStart))
                path.addLine(to: CGPoint(x: 50, y: yEnd))
            }.stroke(.tertiary, lineWidth: 1)
            
            ForEach(getMarkers(), id: \.date) { marker in
                let yPos = metrics.yPosition(for: marker.date, at: zoomScale)
                Path { path in
                    let tickWidth: CGFloat = marker.isMajor ? 10 : 5
                    path.move(to: CGPoint(x: 50 - tickWidth / 2, y: yPos))
                    path.addLine(to: CGPoint(x: 50 + tickWidth / 2, y: yPos))
                }.stroke(.tertiary, lineWidth: marker.isMajor ? 1.5 : 1)
                
                Text(marker.label).font(marker.isMajor ? .caption : .caption2).foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing).offset(x: 0, y: yPos - (marker.isMajor ? 8 : 7))
            }
        }
    }
    
    private func getMarkers() -> [(date: Date, label: String, isMajor: Bool)] {
        let calendar = Calendar.current
        var markers = [(date: Date, label: String, isMajor: Bool)]()
        let minMarkerSpacing: CGFloat = 50.0

        let pointsPerDay = metrics.pointsPerSecond(at: zoomScale) * 86400
        let pointsPerMonth = pointsPerDay * 30
        
        let component: Calendar.Component; let majorMarkerCheck: (Date) -> Bool; let getLabel: (Date, Bool) -> String

        if pointsPerDay > minMarkerSpacing {
            component = .day; majorMarkerCheck = { date in calendar.component(.day, from: date) == 1 }
            getLabel = { date, isMajor in isMajor ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.day()) }
        } else if pointsPerMonth > minMarkerSpacing {
            component = .month; majorMarkerCheck = { date in calendar.component(.month, from: date) == 1 }
            getLabel = { date, isMajor in isMajor ? date.formatted(.dateTime.year()) : date.formatted(.dateTime.month(.abbreviated)) }
        } else {
            component = .year; majorMarkerCheck = { date in calendar.component(.year, from: date) % 5 == 0 }
            getLabel = { date, _ in date.formatted(.dateTime.year()) }
        }
        
        guard let firstMarkerDate = calendar.dateInterval(of: component, for: visibleDateInterval.start)?.start else { return [] }
        var currentDate = firstMarkerDate

        while currentDate <= visibleDateInterval.end {
            markers.append((currentDate, getLabel(currentDate, majorMarkerCheck(currentDate)), majorMarkerCheck(currentDate)))
            guard let nextDate = calendar.date(byAdding: component, value: 1, to: currentDate) else { break }
            currentDate = nextDate
        }
        return markers
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
            let startString: String; let endString: String
            if event.precision == .time {
                startString = event.startDate.formatted(dateFormat) + ", " + event.startDate.formatted(timeFormat)
                if Calendar.current.isDate(event.startDate, inSameDayAs: endDate) { endString = endDate.formatted(timeFormat)
                } else { endString = endDate.formatted(dateFormat) + ", " + endDate.formatted(timeFormat) }
            } else { startString = event.startDate.formatted(dateFormat); endString = endDate.formatted(dateFormat) }
            return startString == endString ? startString : "\(startString) – \(endString)"
        } else {
            return event.precision == .time ? "\(event.startDate.formatted(dateFormat)), \(event.startDate.formatted(timeFormat))" : event.startDate.formatted(dateFormat)
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
                Section { TextField("Title", text: $title); Toggle("Interval Event", isOn: $isIntervalEvent) }
                Section(header: Text(isIntervalEvent ? "Start" : "Date & Time")) {
                    Picker("Precision", selection: $precision) {
                        ForEach(TimePrecision.allCases, id: \.self) { p in Text(p.description).tag(p) }
                    }.pickerStyle(.segmented)
                    DateTimeRow(title: "Date", date: $startDate, precision: precision)
                }
                if isIntervalEvent {
                    Section(header: Text("End")) { DateTimeRow(title: "Date", date: $endDate, precision: precision) }
                }
                Section(header: Text("Description")) { TextEditor(text: $details).frame(minHeight: 150) }
            }
            .navigationTitle(event == nil ? "New Event" : "Edit Event").navigationBarTitleDisplayMode(.inline)
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

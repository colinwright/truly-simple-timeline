import SwiftUI
import SwiftData

// MARK: - Models & Configuration

enum TimePrecision: Int, Codable, CaseIterable, CustomStringConvertible {
    case day = 0, time = 1
    var description: String {
        switch self {
        case .day: return "Date"
        case .time: return "Date & Time"
        }
    }
}

enum TimelineOrientation {
    case vertical, horizontal
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
    
    var isDuration: Bool {
        endDate != nil
    }

    var duration: TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(startDate))
    }
    
    func layoutInterval(using metrics: TimelineMetrics, zoomScale: CGFloat) -> DateInterval {
        let minLengthInSeconds = (44 / metrics.pointsPerSecond(at: zoomScale))
        let effectiveDuration = max(self.duration, minLengthInSeconds)
        return DateInterval(start: self.startDate, duration: effectiveDuration)
    }
}

@Observable
class TimelineConfiguration {
    private let startDateKey = "timelineStartDate"
    private let endDateKey = "timelineEndDate"

    var startDate: Date
    var endDate: Date
    var isConfigured: Bool = false

    init() {
        if let startInterval = UserDefaults.standard.object(forKey: startDateKey) as? TimeInterval,
           let endInterval = UserDefaults.standard.object(forKey: endDateKey) as? TimeInterval {
            self.startDate = Date(timeIntervalSince1970: startInterval)
            self.endDate = Date(timeIntervalSince1970: endInterval)
            self.isConfigured = true
        } else {
            self.startDate = .now.addingTimeInterval(-86400 * 30)
            self.endDate = .now
            self.isConfigured = false
        }
    }

    func save() {
        UserDefaults.standard.set(startDate.timeIntervalSince1970, forKey: startDateKey)
        UserDefaults.standard.set(endDate.timeIntervalSince1970, forKey: endDateKey)
        self.isConfigured = true
    }
}


// MARK: - Main View

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Event.startDate) private var events: [Event]

    @State private var config = TimelineConfiguration()
    @State private var showSettings = false
    @State private var showEventEditor = false
    @State private var eventToEdit: Event?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let orientation: TimelineOrientation = geometry.size.width > geometry.size.height ? .horizontal : .vertical
                
                Group {
                    if !config.isConfigured {
                        ContentUnavailableView( "Setup Your Timeline", systemImage: "calendar.badge.plus", description: Text("Define a start and end date for your timeline to begin.") )
                    } else if events.isEmpty {
                        ContentUnavailableView( "No Events Yet", systemImage: "note.text.badge.plus", description: Text("Tap the + button to add your first event.") )
                    } else {
                        TimelineView(
                            events: events,
                            config: config,
                            orientation: orientation,
                            eventToEdit: $eventToEdit
                        )
                    }
                }
                .navigationTitle("Timeline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { showEventEditor = true } label: { Image(systemName: "plus") }
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { TimelineSettingsView(config: config) }
            .sheet(isPresented: $showEventEditor) { EventEditorView(event: nil, timelineRange: config.dateRange) }
            .sheet(item: $eventToEdit) { event in EventEditorView(event: event, timelineRange: config.dateRange) }
            .onAppear {
                if !config.isConfigured {
                    showSettings = true
                }
            }
        }
    }
}

extension TimelineConfiguration {
    var dateRange: ClosedRange<Date> {
        startDate...endDate
    }
}

// MARK: - Timeline View & Components

struct TimelineView: View {
    let events: [Event]
    let config: TimelineConfiguration
    let orientation: TimelineOrientation
    @Binding var eventToEdit: Event?
    
    @State private var zoomScale: CGFloat = 1.0
    @State private var initialZoomSet = false

    private var metrics: TimelineMetrics {
        TimelineMetrics(bounds: config.dateRange)
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineScrollView(
                events: events,
                metrics: metrics,
                orientation: orientation,
                visibleSize: geometry.size,
                zoomScale: $zoomScale,
                eventToEdit: $eventToEdit
            )
            .onAppear {
                if !initialZoomSet {
                    zoomScale = calculateMinZoom(for: geometry.size)
                    initialZoomSet = true
                }
            }
            .onChange(of: orientation) {
                zoomScale = calculateMinZoom(for: geometry.size)
            }
        }
    }
    
    private func calculateMinZoom(for visibleSize: CGSize) -> CGFloat {
        let axisLength = orientation == .vertical ? visibleSize.height : visibleSize.width
        let totalDuration = config.endDate.timeIntervalSince(config.startDate)
        guard totalDuration > 0, axisLength > 0 else { return 1.0 }
        
        let totalLengthAtScaleOne = metrics.length(for: totalDuration, at: 1.0)
        return totalLengthAtScaleOne > axisLength ? axisLength / totalLengthAtScaleOne : 1.0
    }
}

struct TimelineScrollView: View {
    let events: [Event]
    let metrics: TimelineMetrics
    let orientation: TimelineOrientation
    let visibleSize: CGSize
    
    @Binding var zoomScale: CGFloat
    @Binding var eventToEdit: Event?

    @State private var scrollPosition: CGFloat = 0
    @State private var initialZoomScale: CGFloat?
    @State private var draggingEventID: ObjectIdentifier?
    @State private var dragOffset: CGVector = .zero

    private let axisSize: CGFloat = 60
    private let maxZoomScale: CGFloat = 200.0
    private let scrollCoordinateSpace = "scroll"
    private let contentID = "timelineContent"
    
    private var layouts: [LayoutEvent] {
        let crossAxisSize = orientation == .vertical ? visibleSize.width - axisSize : visibleSize.height - axisSize
        return generateLayouts(containerCrossAxisSize: crossAxisSize)
    }
    
    private var contentSize: CGSize {
        let totalLength = metrics.length(for: metrics.bounds.upperBound.timeIntervalSince(metrics.bounds.lowerBound), at: zoomScale)
        return orientation == .vertical
            ? CGSize(width: visibleSize.width, height: totalLength)
            : CGSize(width: totalLength, height: visibleSize.height)
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(orientation == .vertical ? .vertical : .horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    ScrollPositionTracker(orientation: orientation, coordinateSpace: scrollCoordinateSpace)
                    
                    TimelineBackground(metrics: metrics, zoomScale: zoomScale, orientation: orientation, axisSize: axisSize, visibleSize: visibleSize, scrollPosition: scrollPosition, events: events)

                    ForEach(layouts) { layout in
                        let isBeingDragged = draggingEventID == layout.id
                        EventView(event: layout.event)
                            .frame(width: layout.frame.width, height: layout.frame.height)
                            .offset(x: layout.frame.minX, y: layout.frame.minY)
                            .scaleEffect(isBeingDragged ? 1.05 : 1.0)
                            .opacity(isBeingDragged ? 0.75 : 1.0)
                            .offset(isBeingDragged ? CGSize(width: dragOffset.dx, height: dragOffset.dy) : .zero)
                            .zIndex(isBeingDragged ? 1 : 0)
                            .onTapGesture { eventToEdit = layout.event }
                            .gesture(dragGesture(for: layout.event))
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height)
                .id(contentID)
            }
            .coordinateSpace(name: scrollCoordinateSpace)
            .scrollDisabled(draggingEventID != nil)
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { self.scrollPosition = $0 }
            .simultaneousGesture(magnificationGesture(proxy: proxy))
        }
    }
    
    private func magnificationGesture(proxy: ScrollViewProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard draggingEventID == nil else { return }
                
                let visibleLength = orientation == .vertical ? visibleSize.height : visibleSize.width
                guard visibleLength > 0 else { return }

                let dateAtCenter = metrics.date(at: -scrollPosition + (visibleLength / 2), for: zoomScale)
                
                if initialZoomScale == nil { initialZoomScale = zoomScale }
                if let initial = initialZoomScale {
                    zoomScale = max(calculateMinZoom(), min(maxZoomScale, initial * value))
                }
                
                let newPositionForDate = metrics.position(for: dateAtCenter, at: zoomScale)
                let newScrollOffset = newPositionForDate - (visibleLength / 2)
                let totalLength = orientation == .vertical ? contentSize.height : contentSize.width
                
                if totalLength > 0 {
                    let anchorPoint = orientation == .vertical ? UnitPoint(x: 0, y: newScrollOffset / totalLength) : UnitPoint(x: newScrollOffset / totalLength, y: 0)
                    proxy.scrollTo(contentID, anchor: anchorPoint)
                }
            }
            .onEnded { _ in initialZoomScale = nil }
    }
    
    private func dragGesture(for event: Event) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(scrollCoordinateSpace))
                .onChanged { value in
                    if draggingEventID == nil {
                        draggingEventID = event.id
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    dragOffset = CGVector(dx: value.translation.width, dy: value.translation.height)
                }
                .onEnded { value in
                    let dragLength = orientation == .vertical ? value.translation.height : value.translation.width
                    let timeOffset = dragLength / metrics.pointsPerSecond(at: zoomScale)
                    let originalDuration = event.duration
                    
                    let newStartDate = event.startDate.addingTimeInterval(timeOffset)
                    event.startDate = newStartDate
                    
                    if event.isDuration { event.endDate = newStartDate.addingTimeInterval(originalDuration) }
                    draggingEventID = nil; dragOffset = .zero
                }
            )
    }
    
    private func calculateMinZoom() -> CGFloat {
        let axisLength = orientation == .vertical ? visibleSize.height : visibleSize.width
        let totalDuration = metrics.bounds.upperBound.timeIntervalSince(metrics.bounds.lowerBound)
        guard totalDuration > 0, axisLength > 0 else { return 1.0 }
        let totalLengthAtScaleOne = metrics.length(for: totalDuration, at: 1.0)
        return totalLengthAtScaleOne > axisLength ? axisLength / totalLengthAtScaleOne : 1.0
    }

    private func generateLayouts(containerCrossAxisSize: CGFloat) -> [LayoutEvent] {
        var layouts: [LayoutEvent] = []
        var remainingEvents = events.sorted { $0.startDate < $1.startDate }

        while !remainingEvents.isEmpty {
            var group: [Event] = []
            var queue: [Event] = [remainingEvents.removeFirst()]
            group.append(queue.first!)

            while !queue.isEmpty {
                let current = queue.removeFirst()
                let currentInterval = current.layoutInterval(using: metrics, zoomScale: zoomScale)
                
                let intersecting = remainingEvents.filter {
                    $0.layoutInterval(using: metrics, zoomScale: zoomScale).intersects(currentInterval)
                }
                
                for event in intersecting {
                    group.append(event)
                    queue.append(event)
                }
                remainingEvents.removeAll { intersecting.contains($0) }
            }
            layouts.append(contentsOf: layoutEventGroup(group, containerCrossAxisSize: containerCrossAxisSize))
        }
        return layouts
    }

    private func layoutEventGroup(_ group: [Event], containerCrossAxisSize: CGFloat) -> [LayoutEvent] {
        var eventLayouts: [LayoutEvent] = []
        var laneIntervals: [Int: [DateInterval]] = [:]

        let sortedGroup = group.sorted { $0.startDate < $1.startDate }
        var eventLanes: [ObjectIdentifier: Int] = [:]

        for event in sortedGroup {
            let eventInterval = event.layoutInterval(using: metrics, zoomScale: zoomScale)
            var assignedLane = 0
            while true {
                if let intervalsInLane = laneIntervals[assignedLane], intervalsInLane.contains(where: { $0.intersects(eventInterval) }) {
                    assignedLane += 1
                } else {
                    eventLanes[event.id] = assignedLane
                    laneIntervals[assignedLane, default: []].append(eventInterval)
                    break
                }
            }
        }

        let totalLanes = (laneIntervals.keys.max() ?? -1) + 1
        let laneSize = totalLanes > 0 ? containerCrossAxisSize / CGFloat(totalLanes) : containerCrossAxisSize

        for event in group {
            guard let laneIndex = eventLanes[event.id] else { continue }
            
            let startPos = metrics.position(for: event.startDate, at: zoomScale)
            let length = metrics.length(for: event.duration, at: zoomScale)
            
            let frame: CGRect
            if orientation == .vertical {
                let x = axisSize + (CGFloat(laneIndex) * laneSize)
                frame = CGRect(x: x, y: startPos, width: laneSize, height: length)
            } else {
                let y = axisSize + (CGFloat(laneIndex) * laneSize)
                frame = CGRect(x: startPos, y: y, width: length, height: laneSize)
            }
            eventLayouts.append(LayoutEvent(event: event, frame: frame))
        }
        return eventLayouts
    }
}

// MARK: Timeline Primitives & Helpers
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
struct ScrollPositionTracker: View {
    let orientation: TimelineOrientation
    let coordinateSpace: String
    var body: some View {
        GeometryReader { geometry in
            let offset = orientation == .vertical ? geometry.frame(in: .named(coordinateSpace)).minY : geometry.frame(in: .named(coordinateSpace)).minX
            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: offset)
        }.frame(height: 0)
    }
}
struct LayoutEvent: Identifiable {
    let event: Event
    var frame: CGRect
    var id: ObjectIdentifier { event.id }
}
struct TimelineMetrics {
    let bounds: ClosedRange<Date>
    func pointsPerSecond(at zoomScale: CGFloat) -> CGFloat {
        (120.0 * zoomScale) / 3600
    }
    func position(for date: Date, at zoomScale: CGFloat) -> CGFloat {
        date.timeIntervalSince(bounds.lowerBound) * pointsPerSecond(at: zoomScale)
    }
    func length(for duration: TimeInterval, at zoomScale: CGFloat) -> CGFloat {
        max(duration * pointsPerSecond(at: zoomScale), 44)
    }
    func date(at position: CGFloat, for zoomScale: CGFloat) -> Date {
        bounds.lowerBound.addingTimeInterval(position / pointsPerSecond(at: zoomScale))
    }
    func dateInterval(for position: CGFloat, length: CGFloat, at zoomScale: CGFloat) -> DateInterval {
        DateInterval(start: date(at: position, for: zoomScale), end: date(at: position + length, for: zoomScale))
    }
}

// MARK: Timeline Subviews
struct TimelineBackground: View {
    let metrics: TimelineMetrics, zoomScale: CGFloat, orientation: TimelineOrientation, axisSize: CGFloat, visibleSize: CGSize, scrollPosition: CGFloat, events: [Event]
    var body: some View {
        let visibleLength = orientation == .vertical ? visibleSize.height : visibleSize.width
        let visibleInterval = metrics.dateInterval(for: -scrollPosition, length: visibleLength, at: zoomScale)
        let markers = getMarkers(for: visibleInterval)
        let visibleEvents = events.filter {
            let eventEndDate = $0.endDate ?? $0.startDate
            guard eventEndDate >= $0.startDate else { return false }
            return DateInterval(start: $0.startDate, end: eventEndDate).intersects(visibleInterval)
        }

        ZStack(alignment: .topLeading) {
            Rectangle().fill(.tertiary.opacity(0.5))
                .frame(width: orientation == .vertical ? 1:nil, height: orientation == .horizontal ? 1:nil)
                .offset(x: orientation == .vertical ? axisSize-1:0, y: orientation == .horizontal ? axisSize-1:0)

            ForEach(markers, id: \.date) { marker in
                let pos = metrics.position(for: marker.date, at: zoomScale)
                let tickSize: CGFloat = marker.isMajor ? 10 : 5
                
                if orientation == .vertical {
                    Path { p in p.move(to: CGPoint(x: axisSize - tickSize, y: pos)); p.addLine(to: CGPoint(x: axisSize, y: pos)) }.stroke(.tertiary, lineWidth: 1)
                    Text(marker.label).font(.caption).foregroundColor(.secondary).frame(width: axisSize - tickSize - 4, alignment: .trailing).position(x: (axisSize - tickSize - 4) / 2, y: pos)
                } else {
                    Path { p in p.move(to: CGPoint(x: pos, y: axisSize - tickSize)); p.addLine(to: CGPoint(x: pos, y: axisSize)) }.stroke(.tertiary, lineWidth: 1)
                    Text(marker.label).font(.caption).foregroundColor(.secondary).frame(width: 50).position(x: pos, y: (axisSize - tickSize - 12) / 2)
                }
            }
            
            ForEach(visibleEvents) { event in
                let startPos = metrics.position(for: event.startDate, at: zoomScale)
                if event.isDuration, let endDate = event.endDate {
                    let endPos = metrics.position(for: endDate, at: zoomScale)
                    Capsule().fill(Color.accentColor.opacity(0.7))
                        .frame(width: orientation == .vertical ? 4 : endPos-startPos, height: orientation == .vertical ? endPos-startPos : 4)
                        .offset(x: orientation == .vertical ? axisSize-12 : startPos, y: orientation == .vertical ? startPos : axisSize-12)
                } else {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .position(x: orientation == .vertical ? axisSize-10 : startPos, y: orientation == .vertical ? startPos : axisSize-10)
                }
            }
        }
    }
    private func getMarkers(for visibleInterval: DateInterval) -> [(date: Date, label: String, isMajor: Bool)] {
        var markers: [(Date, String, Bool)] = []
        let calendar = Calendar.current
        let minMarkerSpacing: CGFloat = 70.0
        let pointsPerDay = metrics.pointsPerSecond(at: zoomScale) * 86400, pointsPerHour = metrics.pointsPerSecond(at: zoomScale) * 3600
        let component: Calendar.Component, step: Int, format: Date.FormatStyle
        if pointsPerHour > minMarkerSpacing { component = .hour; step = 1; format = .dateTime.hour() }
        else if pointsPerDay > minMarkerSpacing*2 { component = .day; step = 1; format = .dateTime.weekday().day() }
        else if pointsPerDay > minMarkerSpacing { component = .day; step = 2; format = .dateTime.month().day() }
        else if metrics.length(for: 86400 * 30, at: zoomScale) > minMarkerSpacing { component = .month; step = 1; format = .dateTime.month(.abbreviated) }
        else { component = .year; step = 1; format = .dateTime.year() }
        guard let startMarkerDate = calendar.dateInterval(of: component, for: visibleInterval.start)?.start else { return [] }
        var currentDate = startMarkerDate
        while currentDate <= visibleInterval.end {
            markers.append((currentDate, currentDate.formatted(format), false))
            guard let nextDate = calendar.date(byAdding: component, value: step, to: currentDate) else { break }
            currentDate = nextDate
        }
        return markers
    }
}
struct EventView: View {
    let event: Event
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
            Text(dateString()).font(.caption).foregroundColor(.secondary).lineLimit(2)
            if !event.details.isEmpty { Text(event.details).font(.caption).foregroundColor(.secondary).padding(.top, 2).lineLimit(4) }
            Spacer(minLength: 0)
        }.padding(8).background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
    private func dateString() -> String {
        let dateFormat = Date.FormatStyle.dateTime.month(.abbreviated).day().year(), timeFormat = Date.FormatStyle.dateTime.hour().minute()
        let startString = event.precision == .time ? event.startDate.formatted(dateFormat) + ", " + event.startDate.formatted(timeFormat) : event.startDate.formatted(dateFormat)
        guard let endDate = event.endDate else { return startString }
        let endString: String
        if event.precision == .time { let sameDay = Calendar.current.isDate(event.startDate, inSameDayAs: endDate); endString = sameDay ? endDate.formatted(timeFormat) : endDate.formatted(dateFormat) + ", " + endDate.formatted(timeFormat)
        } else { endString = endDate.formatted(dateFormat) }
        return startString == endString ? startString : "\(startString) – \(endString)"
    }
}

// MARK: - Settings & Editor Views
struct TimelineSettingsView: View {
    @Bindable var config: TimelineConfiguration
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Timeline Range") {
                    DatePicker("Start Date", selection: $config.startDate, displayedComponents: .date)
                    DatePicker("End Date", selection: $config.endDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Timeline Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        config.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
struct EventEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss
    
    let event: Event?
    let timelineRange: ClosedRange<Date>
    
    @State private var title: String = ""
    @State private var details: String = ""
    @State private var startDate: Date = .now
    @State private var endDate: Date? = nil
    @State private var precision: TimePrecision = .day
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) }
                
                Section("Precision") {
                    Picker("Precision", selection: $precision.animation()) {
                        ForEach(TimePrecision.allCases, id: \.self) { p in Text(p.description).tag(p) }
                    }.pickerStyle(.segmented)
                }
                
                Section("Start") {
                    DatePicker("Date", selection: $startDate, in: timelineRange, displayedComponents: precision == .time ? [.date, .hourAndMinute] : [.date])
                }
                
                Section("End") {
                    if let binding = Binding($endDate) {
                        DatePicker("Date", selection: binding, in: startDate..., displayedComponents: precision == .time ? [.date, .hourAndMinute] : [.date])
                        Button("Remove End Date", role: .destructive) { endDate = nil }
                    } else {
                        Button("Add End Date") { endDate = startDate.addingTimeInterval(3600) }
                    }
                }
                
                Section("Description") {
                    TextEditor(text: $details).frame(minHeight: 120)
                }
                
                if event != nil {
                    Section {
                        Button("Delete Event", role: .destructive) { showDeleteConfirmation = true }
                    }
                }
            }
            .navigationTitle(event == nil ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(title.isEmpty) }
            }
            .onAppear(perform: setupInitialState)
            .onChange(of: precision) { _, newPrecision in
                if newPrecision == .day {
                    self.startDate = Calendar.current.startOfDay(for: startDate)
                    if let currentEndDate = self.endDate {
                        self.endDate = Calendar.current.startOfDay(for: currentEndDate)
                    }
                }
            }
            .alert("Delete Event?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive, action: deleteEvent)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone.")
            }
        }
    }
    
    private func setupInitialState() {
        if let event {
            title = event.title
            details = event.details
            startDate = event.startDate
            endDate = event.endDate
            precision = event.precision
        } else {
            startDate = Calendar.current.date(byAdding: .day, value: 1, to: timelineRange.lowerBound) ?? .now
        }
    }
    
    private func save() {
        if let event {
            event.title = title
            event.details = details
            event.startDate = startDate
            event.endDate = endDate
            event.precision = precision
        } else {
            let newEvent = Event(startDate: startDate, endDate: endDate, title: title, details: details, precision: precision)
            modelContext.insert(newEvent)
        }
        dismiss()
    }
    
    private func deleteEvent() {
        if let event {
            modelContext.delete(event)
        }
        dismiss()
    }
}

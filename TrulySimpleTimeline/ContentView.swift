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
    
    var effectiveDuration: TimeInterval {
        if precision == .day && isDuration {
            return duration + 86400
        }
        return duration
    }
    
    func layoutInterval(using metrics: TimelineMetrics, zoomScale: CGFloat) -> DateInterval {
        let minLengthInSeconds = (44 / metrics.pointsPerSecond(at: zoomScale))
        let durationForLayout = max(self.effectiveDuration, minLengthInSeconds)
        return DateInterval(start: self.startDate, duration: durationForLayout)
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
                    } else {
                        TimelineView(
                            events: events,
                            config: config,
                            orientation: orientation,
                            visibleSize: geometry.size,
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
    let visibleSize: CGSize
    @Binding var eventToEdit: Event?
    
    @State private var zoomScale: CGFloat = 1.0
    @State private var centerDate: Date?

    private var metrics: TimelineMetrics { TimelineMetrics(config: config) }

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView("No Events Yet", systemImage: "note.text.badge.plus", description: Text("Tap the + button to add your first event."))
            } else if let centerDateBinding = Binding($centerDate) {
                TimelineScrollView(
                    events: events,
                    metrics: metrics,
                    orientation: orientation,
                    visibleSize: visibleSize,
                    zoomScale: $zoomScale,
                    centerDate: centerDateBinding,
                    eventToEdit: $eventToEdit
                )
            } else {
                Color.clear
            }
        }
        .onChange(of: visibleSize) { _, newSize in
            guard centerDate == nil, newSize.width > 0, newSize.height > 0 else { return }
            
            let axisLength = orientation == .vertical ? newSize.height : newSize.width
            zoomScale = metrics.calculateMinZoom(for: axisLength)

            let totalDuration = config.endDate.timeIntervalSince(config.startDate)
            centerDate = config.startDate.addingTimeInterval(totalDuration / 2.0)
        }
    }
}

struct TimelineScrollView: View {
    let events: [Event]
    let metrics: TimelineMetrics
    let orientation: TimelineOrientation
    let visibleSize: CGSize
    
    @Binding var zoomScale: CGFloat
    @Binding var centerDate: Date
    @Binding var eventToEdit: Event?

    @State private var scrollPosition: CGFloat = 0
    @State private var initialZoomScale: CGFloat?
    @State private var draggingEventID: ObjectIdentifier?
    @State private var dragOffset: CGVector = .zero
    @State private var scrollUpdateTask: Task<Void, Never>?
    
    private let axisSize: CGFloat = 60
    private let maxZoomScale: CGFloat = 200.0
    private let scrollCoordinateSpace = "scroll"
    private let contentID = "timelineContent"
    
    private var layouts: [LayoutEvent] {
        let crossAxisSize = orientation == .vertical ? visibleSize.width - axisSize : visibleSize.height - axisSize
        return generateLayouts(containerCrossAxisSize: crossAxisSize)
    }
    
    private var contentSize: CGSize {
        let totalLength = metrics.pureLength(for: metrics.config.dateRange.upperBound.timeIntervalSince(metrics.config.dateRange.lowerBound), at: zoomScale)
        return orientation == .vertical
            ? CGSize(width: visibleSize.width, height: totalLength)
            : CGSize(width: totalLength, height: visibleSize.height)
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(orientation == .vertical ? .vertical : .horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    ScrollPositionTracker(orientation: orientation, scrollPosition: $scrollPosition, coordinateSpace: scrollCoordinateSpace)
                    TimelineBackground(metrics: metrics, zoomScale: zoomScale, orientation: orientation, axisSize: axisSize, visibleSize: visibleSize, scrollPosition: $scrollPosition, events: events)
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
            .simultaneousGesture(magnificationGesture(proxy: proxy))
            .onAppear { scrollTo(date: centerDate, proxy: proxy, animated: false) }
            .onChange(of: visibleSize) { _, _ in scrollTo(date: centerDate, proxy: proxy, animated: false) }
            .onChange(of: scrollPosition) { _, newPosition in
                updateCenterDateFromScroll(position: newPosition)
            }
        }
    }
    
    private func scrollTo(date: Date, proxy: ScrollViewProxy, animated: Bool) {
        let axisLength = orientation == .vertical ? visibleSize.height : visibleSize.width
        guard axisLength > 0 else { return }

        let targetPosition = metrics.position(for: date, at: zoomScale)
        let scrollOffset = targetPosition - (axisLength / 2)
        
        let totalLength = orientation == .vertical ? contentSize.height : contentSize.width
        guard totalLength > 0 else { return }

        let anchor = orientation == .vertical
            ? UnitPoint(x: 0, y: scrollOffset / totalLength)
            : UnitPoint(x: scrollOffset / totalLength, y: 0)
        
        if animated {
            withAnimation { proxy.scrollTo(contentID, anchor: anchor) }
        } else {
            proxy.scrollTo(contentID, anchor: anchor)
        }
    }
    
    private func updateCenterDateFromScroll(position: CGFloat) {
        scrollUpdateTask?.cancel()
        scrollUpdateTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(50))
                let axisLength = orientation == .vertical ? visibleSize.height : visibleSize.width
                let newCenterDate = metrics.date(at: -position + (axisLength / 2), for: zoomScale)
                
                await MainActor.run {
                    self.centerDate = newCenterDate
                }
            } catch {
                // Task was cancelled.
            }
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
            .onEnded { _ in
                initialZoomScale = nil
                updateCenterDateFromScroll(position: scrollPosition)
            }
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
        return metrics.calculateMinZoom(for: axisLength)
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
            let length = metrics.length(for: event.effectiveDuration, at: zoomScale)
            
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
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
struct ScrollPositionTracker: View {
    let orientation: TimelineOrientation
    @Binding var scrollPosition: CGFloat
    let coordinateSpace: String
    
    var body: some View {
        GeometryReader { g in
            let offset = orientation == .vertical ? g.frame(in: .named(coordinateSpace)).minY : g.frame(in: .named(coordinateSpace)).minX
            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: offset)
        }
        .frame(height: 0)
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            scrollPosition = value
        }
    }
}
struct LayoutEvent: Identifiable {
    let event: Event
    var frame: CGRect
    var id: ObjectIdentifier { event.id }
}
struct TimelineMetrics {
    let config: TimelineConfiguration
    var bounds: ClosedRange<Date> { config.dateRange }
    
    func pointsPerSecond(at zoomScale: CGFloat) -> CGFloat { (120.0 * zoomScale) / 3600 }
    func position(for date: Date, at zoomScale: CGFloat) -> CGFloat { date.timeIntervalSince(bounds.lowerBound) * pointsPerSecond(at: zoomScale) }
    func pureLength(for duration: TimeInterval, at zoomScale: CGFloat) -> CGFloat { duration * pointsPerSecond(at: zoomScale) }
    func length(for duration: TimeInterval, at zoomScale: CGFloat) -> CGFloat { max(pureLength(for: duration, at: zoomScale), 44) }
    func date(at position: CGFloat, for zoomScale: CGFloat) -> Date { bounds.lowerBound.addingTimeInterval(position / pointsPerSecond(at: zoomScale)) }
    func dateInterval(for position: CGFloat, length: CGFloat, at zoomScale: CGFloat) -> DateInterval { DateInterval(start: date(at: position, for: zoomScale), end: date(at: position + length, for: zoomScale)) }
    
    func calculateMinZoom(for axisLength: CGFloat) -> CGFloat {
        let totalDuration = config.dateRange.upperBound.timeIntervalSince(config.dateRange.lowerBound)
        guard totalDuration > 0, axisLength > 0 else { return 1.0 }
        
        let totalLengthAtScaleOne = pureLength(for: totalDuration, at: 1.0)
        
        return totalLengthAtScaleOne > axisLength ? axisLength / totalLengthAtScaleOne : 1.0
    }
}

struct RenderableRegion {
    var markers: [(date: Date, label: String, isMajor: Bool)] = []
    var events: [Event] = []
}

// MARK: Timeline Subviews
struct TimelineBackground: View {
    let metrics: TimelineMetrics, zoomScale: CGFloat, orientation: TimelineOrientation, axisSize: CGFloat, visibleSize: CGSize
    @Binding var scrollPosition: CGFloat
    let events: [Event]
    
    @State private var renderableRegion = RenderableRegion()
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.tertiary.opacity(0.5))
                .frame(width: orientation == .vertical ? 1:nil, height: orientation == .horizontal ? 1:nil)
                .offset(x: orientation == .vertical ? axisSize-1:0, y: orientation == .horizontal ? axisSize-1:0)

            ForEach(renderableRegion.markers, id: \.date) { marker in
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
            
            ForEach(renderableRegion.events) { event in
                let startPos = metrics.position(for: event.startDate, at: zoomScale)
                if event.isDuration {
                    let markerLength = event.effectiveDuration * metrics.pointsPerSecond(at: zoomScale)
                    if markerLength > 0.5 {
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: orientation == .vertical ? 4 : markerLength, height: orientation == .vertical ? markerLength : 4)
                            .offset(x: orientation == .vertical ? axisSize-12 : startPos, y: orientation == .vertical ? startPos : axisSize-12)
                    }
                } else {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .position(x: orientation == .vertical ? axisSize-10 : startPos, y: orientation == .vertical ? startPos : axisSize-10)
                }
            }
        }
        .onAppear { updateRenderableRegion() }
        .onChange(of: scrollPosition) { _, _ in updateRenderableRegion(debounced: true) }
        .onChange(of: zoomScale) { _, _ in updateRenderableRegion() }
        .onChange(of: visibleSize) { _, _ in updateRenderableRegion() }
    }
    
    private func updateRenderableRegion(debounced: Bool = false) {
        debounceTask?.cancel()
        
        let newRenderTask = Task {
            if debounced {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            
            let visibleLength = orientation == .vertical ? visibleSize.height : visibleSize.width
            guard visibleLength > 0 else { return }
            
            let visibleInterval = metrics.dateInterval(for: -scrollPosition, length: visibleLength, at: zoomScale)
            
            let bufferDuration = visibleInterval.duration * 4.0
            let bufferedInterval = DateInterval(start: visibleInterval.start.addingTimeInterval(-bufferDuration), end: visibleInterval.end.addingTimeInterval(bufferDuration))
            
            let newMarkers = getMarkers(for: bufferedInterval)
            let newEvents = events.filter {
                if $0.isDuration {
                    return bufferedInterval.intersects(DateInterval(start: $0.startDate, duration: $0.effectiveDuration))
                } else {
                    return bufferedInterval.contains($0.startDate)
                }
            }
            await MainActor.run {
                renderableRegion = RenderableRegion(markers: newMarkers, events: newEvents)
            }
        }
        self.debounceTask = newRenderTask
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
            details = details
            startDate = startDate
            endDate = endDate
            precision = precision
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

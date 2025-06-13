import SwiftUI
import SwiftData

// MARK: - Models & Configuration

@Model
final class Character {
    @Attribute(.unique) var name: String
    var events: [Event]?
    
    init(name: String) {
        self.name = name
    }
}

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
    var colorHex: String?
    
    @Relationship(inverse: \Character.events)
    var characters: [Character]?

    init(startDate: Date, endDate: Date? = nil, title: String, details: String, precision: TimePrecision = .day, colorHex: String? = nil) {
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.details = details
        self.precision = precision
        self.colorHex = colorHex
    }
    
    var color: Color {
        Color(hex: colorHex) ?? .accentColor
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
    
    func layoutInterval(using metrics: TimelineMetrics, zoomScale: CGFloat, orientation: TimelineOrientation) -> DateInterval {
        let minPoints = orientation == .horizontal ? 180.0 : 44.0
        let minLengthInSeconds = (minPoints / metrics.pointsPerSecond(at: zoomScale))
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

fileprivate struct UndoState {
    let eventID: PersistentIdentifier
    let oldStartDate: Date
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Event.startDate) private var events: [Event]

    @State private var config = TimelineConfiguration()
    @State private var showSettings = false
    @State private var showEventEditor = false
    @State private var eventToEdit: Event?

    @State private var zoomScale: CGFloat = 1.0
    @State private var centerDate: Date?
    
    @State private var isDragEnabled = true
    @State private var undoState: UndoState?

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
                            eventToEdit: $eventToEdit,
                            zoomScale: $zoomScale,
                            centerDate: $centerDate,
                            isDragEnabled: isDragEnabled,
                            onEventMoved: { event, oldStartDate in
                                undoState = UndoState(eventID: event.persistentModelID, oldStartDate: oldStartDate)
                            }
                        )
                    }
                }
                .navigationTitle("Timeline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { undoLastMove() }
                            .disabled(undoState == nil)
                        
                        Button { isDragEnabled.toggle() } label: { Image(systemName: isDragEnabled ? "lock.open" : "lock") }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { showEventEditor = true } label: { Image(systemName: "plus") }
                        
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                .task(id: config.isConfigured) {
                    guard config.isConfigured else { return }
                    
                    let axisLength = orientation == .vertical ? geometry.size.height : geometry.size.width
                    guard axisLength > 0 else { return }

                    let metrics = TimelineMetrics(config: config)
                    let totalDuration = config.endDate.timeIntervalSince(config.startDate)

                    zoomScale = metrics.calculateMinZoom(for: axisLength)
                    centerDate = config.startDate.addingTimeInterval(totalDuration / 2.0)
                }
            }
            .sheet(isPresented: $showSettings) { TimelineSettingsView(config: config) }
            .sheet(isPresented: $showEventEditor) { EventEditorView(timelineRange: config.dateRange) }
            .sheet(item: $eventToEdit) { event in EventEditorView(event: event, timelineRange: config.dateRange) }
            .onAppear {
                if !config.isConfigured {
                    showSettings = true
                }
            }
            .onChange(of: showEventEditor) { _, isShowing in if isShowing { undoState = nil } }
            .onChange(of: eventToEdit) { _, event in if event != nil { undoState = nil } }
        }
    }
    
    private func undoLastMove() {
        guard let undoState = self.undoState else { return }
        
        if let eventToUndo = events.first(where: { $0.persistentModelID == undoState.eventID }) {
            let originalDuration = eventToUndo.duration
            eventToUndo.startDate = undoState.oldStartDate
            if eventToUndo.isDuration {
                eventToUndo.endDate = undoState.oldStartDate.addingTimeInterval(originalDuration)
            }
        }
        self.undoState = nil
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
    @Binding var zoomScale: CGFloat
    @Binding var centerDate: Date?
    
    let isDragEnabled: Bool
    let onEventMoved: (Event, Date) -> Void
    
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
                    eventToEdit: $eventToEdit,
                    isDragEnabled: isDragEnabled,
                    onEventMoved: onEventMoved
                )
            } else {
                Color.clear
            }
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
    
    let isDragEnabled: Bool
    let onEventMoved: (Event, Date) -> Void

    private struct DragState {
        let event: Event
        let originalStartDate: Date
    }
    
    @State private var dragState: DragState?
    @State private var scrollPosition: CGFloat = 0
    @State private var initialZoomScale: CGFloat?
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
                        let isBeingDragged = dragState?.event.id == layout.id
                        EventView(event: layout.event, orientation: orientation)
                            .frame(width: layout.frame.width, height: layout.frame.height)
                            .offset(x: layout.frame.minX, y: layout.frame.minY)
                            .scaleEffect(isBeingDragged ? 1.05 : 1.0)
                            .opacity(isBeingDragged ? 0.75 : 1.0)
                            .zIndex(isBeingDragged ? 1 : 0)
                            .onTapGesture { eventToEdit = layout.event }
                            .if(isDragEnabled) { view in
                                view.gesture(dragGesture(for: layout.event))
                            }
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height)
                .id(contentID)
            }
            .coordinateSpace(name: scrollCoordinateSpace)
            .scrollDisabled(dragState != nil)
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
            } catch { /* Task was cancelled. */ }
        }
    }
    
    private func magnificationGesture(proxy: ScrollViewProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard dragState == nil else { return }
                
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
                    if dragState == nil {
                        dragState = DragState(event: event, originalStartDate: event.startDate)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    
                    guard let currentDrag = dragState else { return }
                    
                    let dragLength = orientation == .vertical ? value.translation.height : value.translation.width
                    let timeOffset = dragLength / metrics.pointsPerSecond(at: zoomScale)
                    let originalDuration = currentDrag.event.duration
                    
                    let newStartDate = currentDrag.originalStartDate.addingTimeInterval(timeOffset)
                    currentDrag.event.startDate = newStartDate
                    
                    if currentDrag.event.isDuration {
                        currentDrag.event.endDate = newStartDate.addingTimeInterval(originalDuration)
                    }
                }
                .onEnded { value in
                    guard let endedDrag = dragState else { return }
                    onEventMoved(endedDrag.event, endedDrag.originalStartDate)
                    dragState = nil
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
                let currentInterval = current.layoutInterval(using: metrics, zoomScale: zoomScale, orientation: orientation)
                
                let intersecting = remainingEvents.filter {
                    $0.layoutInterval(using: metrics, zoomScale: zoomScale, orientation: orientation).intersects(currentInterval)
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
            let eventInterval = event.layoutInterval(using: metrics, zoomScale: zoomScale, orientation: orientation)
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
            
            let minPoints = orientation == .horizontal ? 180.0 : 44.0
            let mainAxisLength = max(metrics.pureLength(for: event.effectiveDuration, at: zoomScale), minPoints)
            
            let frame: CGRect
            if orientation == .vertical {
                let x = axisSize + (CGFloat(laneIndex) * laneSize)
                frame = CGRect(x: x, y: startPos, width: laneSize, height: mainAxisLength)
            } else {
                let y = axisSize + (CGFloat(laneIndex) * laneSize)
                frame = CGRect(x: startPos, y: y, width: mainAxisLength, height: laneSize)
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
                        Capsule().fill(event.color.opacity(0.7))
                            .frame(width: orientation == .vertical ? 4 : markerLength, height: orientation == .vertical ? markerLength : 4)
                            .offset(x: orientation == .vertical ? axisSize-12 : startPos, y: orientation == .vertical ? startPos : axisSize-12)
                    }
                } else {
                    Circle().fill(event.color).frame(width: 6, height: 6)
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
    let orientation: TimelineOrientation
    
    var body: some View {
        Group {
            if orientation == .vertical {
                verticalBody
            } else {
                horizontalBody
            }
        }
        .padding(8)
        .background(event.color.opacity(0.2))
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
    
    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
            Text(dateString()).font(.caption).foregroundColor(.secondary).lineLimit(2)
            if !event.details.isEmpty {
                Text(event.details).font(.caption).foregroundColor(.secondary).padding(.top, 2).lineLimit(4)
            }
            
            Spacer(minLength: 0)
            
            characterList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var horizontalBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
            
            Text(dateString())
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            if !event.details.isEmpty {
                Text(event.details)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.top, 2)
                    .lineLimit(3)
            }
            
            Spacer(minLength: 4)
            
            characterList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    @ViewBuilder
    private var characterList: some View {
        if let characters = event.characters, !characters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(characters.sorted(by: { $0.name < $1.name })) { character in
                        Text(character.name)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.top, 4)
        }
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
    
    @Query(sort: \Character.name) private var allCharacters: [Character]
    
    var event: Event?
    let timelineRange: ClosedRange<Date>
    var initialDate: Date? = nil
    
    @State private var title: String = ""
    @State private var details: String = ""
    @State private var startDate: Date = .now
    @State private var endDate: Date? = nil
    @State private var precision: TimePrecision = .day
    @State private var showDeleteConfirmation = false
    
    @State private var colorHex: String?
    @State private var selectedCharacters = Set<Character>()
    
    @State private var showAddCharacterAlert = false
    @State private var newCharacterName = ""
    
    private let presetColors: [ColorChoice] = ColorChoice.presets
    
    private var unselectedCharacters: [Character] {
        allCharacters.filter { !selectedCharacters.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) }
                
                Section("Look") {
                    HStack {
                        ForEach(presetColors) { choice in
                            Circle()
                                .fill(choice.color)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().stroke(Color.primary, lineWidth: colorHex == choice.id ? 2 : 0)
                                )
                                .onTapGesture { colorHex = choice.id }
                        }
                    }
                    if colorHex != nil {
                        Button("Clear Color", role: .destructive) { colorHex = nil }
                    }
                }
                
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
                
                Section("Characters") {
                    ForEach(Array(selectedCharacters).sorted(by: { $0.name < $1.name })) { char in
                        HStack {
                            Text(char.name)
                            Spacer()
                            Button { selectedCharacters.remove(char) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        }.buttonStyle(.borderless)
                    }
                    
                    Menu("Add Character") {
                        if !unselectedCharacters.isEmpty {
                            ForEach(unselectedCharacters) { char in
                                Button(char.name) { selectedCharacters.insert(char) }
                            }
                            Divider()
                        }
                        Button("Add New Character...") {
                            newCharacterName = ""
                            showAddCharacterAlert = true
                        }
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
            } message: { Text("This action cannot be undone.") }
            .alert("New Character", isPresented: $showAddCharacterAlert) {
                TextField("Name", text: $newCharacterName)
                Button("Add", action: createAndSelectCharacter).disabled(newCharacterName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
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
            colorHex = event.colorHex
            selectedCharacters = Set(event.characters ?? [])
        } else {
            startDate = initialDate ?? Calendar.current.date(byAdding: .day, value: 1, to: timelineRange.lowerBound) ?? .now
            if precision == .day {
                startDate = Calendar.current.startOfDay(for: startDate)
            }
        }
    }
    
    private func save() {
        let eventToSave: Event
        if let event {
            eventToSave = event
        } else {
            eventToSave = Event(startDate: startDate, endDate: endDate, title: title, details: details, precision: precision)
            modelContext.insert(eventToSave)
        }

        eventToSave.title = title
        eventToSave.details = details
        eventToSave.startDate = startDate
        eventToSave.endDate = endDate
        eventToSave.precision = precision
        eventToSave.colorHex = colorHex
        eventToSave.characters = Array(selectedCharacters)
        
        dismiss()
    }
    
    private func deleteEvent() {
        if let event { modelContext.delete(event) }
        dismiss()
    }
    
    private func createAndSelectCharacter() {
        let trimmedName = newCharacterName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        
        let newCharacter = Character(name: trimmedName)
        modelContext.insert(newCharacter)
        selectedCharacters.insert(newCharacter)
    }
}


// MARK: - Color Helpers

struct ColorChoice: Identifiable, Hashable {
    let id: String // hex
    let color: Color
    
    static let presets: [ColorChoice] = [
        .init(id: "#5792F2", color: .blue),
        .init(id: "#4CAF50", color: .green),
        .init(id: "#FFC107", color: .yellow),
        .init(id: "#FF9800", color: .orange),
        .init(id: "#F44336", color: .red),
        .init(id: "#9C27B0", color: .purple),
        .init(id: "#607D8B", color: .gray)
    ]
}

extension Color {
    init?(hex: String?) {
        guard var hex = hex else { return nil }
        hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: return nil
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

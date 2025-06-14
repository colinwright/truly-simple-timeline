import SwiftUI
import SwiftData

// MARK: - Models & Configuration

@Model
final class Person {
    @Attribute(.unique) var name: String
    var events: [Event]?
    
    init(name: String) {
        self.name = name
    }
}

@Model
final class Location {
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
    var isArcEvent: Bool = false
    
    @Relationship(inverse: \Person.events)
    var people: [Person]?

    @Relationship(inverse: \Location.events)
    var locations: [Location]?

    init(startDate: Date, endDate: Date? = nil, title: String, details: String, precision: TimePrecision = .day, colorHex: String? = nil, isArcEvent: Bool = false) {
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.details = details
        self.precision = precision
        self.colorHex = colorHex
        self.isArcEvent = isArcEvent
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
        if precision == .day, let endDate = self.endDate {
            let calendar = Calendar.current
            let startDay = calendar.startOfDay(for: startDate)
            let endDay = calendar.startOfDay(for: endDate)
            return endDay.timeIntervalSince(startDay) + 86400
        }
        return duration
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

@Observable
class DisplaySettings {
    private let showTitleKey = "displayShowTitle"
    private let showDetailsKey = "displayShowDetails"
    private let showPeopleKey = "displayShowPeople"
    private let showLocationsKey = "displayShowLocations"
    private let isDragEnabledKey = "displayIsDragEnabled"
    private let isTapToAddEnabledKey = "displayIsTapToAddEnabled"
    
    var showTitle: Bool
    var showDetails: Bool
    var showPeople: Bool
    var showLocations: Bool
    var isDragEnabled: Bool
    var isTapToAddEnabled: Bool

    init() {
        let defaults = UserDefaults.standard
        self.showTitle = defaults.object(forKey: showTitleKey) as? Bool ?? true
        self.showDetails = defaults.object(forKey: showDetailsKey) as? Bool ?? true
        self.showPeople = defaults.object(forKey: showPeopleKey) as? Bool ?? true
        self.showLocations = defaults.object(forKey: showLocationsKey) as? Bool ?? true
        self.isDragEnabled = defaults.object(forKey: isDragEnabledKey) as? Bool ?? true
        self.isTapToAddEnabled = defaults.object(forKey: isTapToAddEnabledKey) as? Bool ?? true
    }
    
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(showTitle, forKey: showTitleKey)
        defaults.set(showDetails, forKey: showDetailsKey)
        defaults.set(showPeople, forKey: showPeopleKey)
        defaults.set(showLocations, forKey: showLocationsKey)
        defaults.set(isDragEnabled, forKey: isDragEnabledKey)
        defaults.set(isTapToAddEnabled, forKey: isTapToAddEnabledKey)
    }
}


// MARK: - Undo/Redo Manager

@Observable
class UndoRedoManager {
    private enum Action {
        case move(eventID: PersistentIdentifier, from: Date, to: Date)
    }

    private var undoStack: [Action] = []
    private var redoStack: [Action] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func addMoveAction(event: Event, from oldDate: Date) {
        let action = Action.move(eventID: event.persistentModelID, from: oldDate, to: event.startDate)
        undoStack.append(action)
        redoStack.removeAll()
    }

    func performUndo(on events: [Event]) {
        guard let action = undoStack.popLast() else { return }
        
        switch action {
        case .move(let eventID, let fromDate, let toDate):
            if let event = findEvent(by: eventID, in: events) {
                applyMove(to: event, newDate: fromDate)
                let redoAction = Action.move(eventID: eventID, from: fromDate, to: toDate)
                redoStack.append(redoAction)
            }
        }
    }

    func performRedo(on events: [Event]) {
        guard let action = redoStack.popLast() else { return }
        
        switch action {
        case .move(let eventID, let fromDate, let toDate):
            if let event = findEvent(by: eventID, in: events) {
                applyMove(to: event, newDate: toDate)
                let undoAction = Action.move(eventID: eventID, from: fromDate, to: toDate)
                undoStack.append(undoAction)
            }
        }
    }
    
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func findEvent(by id: PersistentIdentifier, in events: [Event]) -> Event? {
        return events.first { $0.persistentModelID == id }
    }
    
    private func applyMove(to event: Event, newDate: Date) {
        let duration = event.duration
        event.startDate = newDate
        if event.isDuration {
            event.endDate = newDate.addingTimeInterval(duration)
        }
    }
}


// MARK: - Main View

fileprivate struct NewEventRequest: Identifiable {
    let id = UUID()
    let date: Date
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Event.startDate) private var events: [Event]

    @State private var config = TimelineConfiguration()
    @State private var displaySettings = DisplaySettings()
    @State private var showSettings = false
    @State private var showEventEditor = false
    @State private var eventToEdit: Event?
    @State private var newEventRequest: NewEventRequest?
    @State private var showScrollToDateView = false
    @State private var showGoToMenu = false

    @State private var zoomScale: CGFloat = 1.0
    @State private var centerDate: Date?
    @State private var scrollPosition: CGFloat = 0
    @State private var timelineVisibleSize: CGSize = .zero
    @State private var isScrollingProgrammatically = false
    @State private var scrollEndDebounceTask: Task<Void, Never>?
    
    @State private var undoRedoManager = UndoRedoManager()
    
    private var canScrollToNext: Bool {
        guard let visibleInterval = getVisibleInterval() else { return false }
        return events.contains { $0.startDate > visibleInterval.end }
    }

    private var canScrollToPrevious: Bool {
        guard let visibleInterval = getVisibleInterval() else { return false }
        return events.contains { $0.startDate < visibleInterval.start }
    }

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
                            displaySettings: displaySettings,
                            orientation: orientation,
                            visibleSize: geometry.size,
                            eventToEdit: $eventToEdit,
                            zoomScale: $zoomScale,
                            centerDate: $centerDate,
                            scrollPosition: $scrollPosition,
                            isScrollingProgrammatically: $isScrollingProgrammatically,
                            onEventMoved: { event, oldStartDate in
                                undoRedoManager.addMoveAction(event: event, from: oldStartDate)
                            },
                            onTapDate: { date in
                                newEventRequest = NewEventRequest(date: date)
                            }
                        )
                    }
                }
                .onAppear { timelineVisibleSize = geometry.size }
                .onChange(of: geometry.size) { _, newSize in timelineVisibleSize = newSize }
                .navigationTitle("Timeline")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { undoRedoManager.performUndo(on: events) }
                            .disabled(!undoRedoManager.canUndo)
                        
                        Button("Redo", systemImage: "arrow.uturn.forward") { undoRedoManager.performRedo(on: events) }
                            .disabled(!undoRedoManager.canRedo)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button {
                            showGoToMenu = true
                        } label: {
                            Label("Go To", systemImage: "magnifyingglass")
                        }
                        .popover(isPresented: $showGoToMenu) {
                            goToMenuContent
                                .presentationCompactAdaptation(.popover)
                        }
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
            .sheet(isPresented: $showSettings) { TimelineSettingsView(config: config, displaySettings: displaySettings) }
            .sheet(isPresented: $showEventEditor) { EventEditorView(timelineRange: config.dateRange) }
            .sheet(item: $eventToEdit) { event in EventEditorView(event: event, timelineRange: config.dateRange) }
            .sheet(item: $newEventRequest) { request in
                EventEditorView(timelineRange: config.dateRange, initialDate: request.date)
            }
            .sheet(isPresented: $showScrollToDateView) {
                ScrollToDateView(timelineRange: config.dateRange) { date in
                    programmaticallyScroll(toDate: date)
                    showScrollToDateView = false
                }
            }
            .onAppear {
                if !config.isConfigured {
                    showSettings = true
                }
            }
            .onChange(of: showEventEditor) { _, isShowing in if isShowing { undoRedoManager.clearHistory() } }
            .onChange(of: eventToEdit) { _, event in if event != nil { undoRedoManager.clearHistory() } }
            .onChange(of: scrollPosition) { _, newPosition in
                scrollEndDebounceTask?.cancel()
                scrollEndDebounceTask = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                        if isScrollingProgrammatically {
                             isScrollingProgrammatically = false
                        } else {
                            updateCenterDateFromScroll(position: newPosition)
                        }
                    } catch { /* Task cancelled by new scroll event */ }
                }
            }
        }
    }
    
    private var goToMenuContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { scrollToPreviousEvent() } label: { Label("Previous Event", systemImage: "arrow.backward.to.line") }
                .disabled(!canScrollToPrevious)
            Button { scrollToNextEvent() } label: { Label("Next Event", systemImage: "arrow.forward.to.line") }
                .disabled(!canScrollToNext)
            Button { showScrollToDateView = true } label: { Label("Go to Date...", systemImage: "calendar") }
        }
        .padding()
        .buttonStyle(.plain)
    }
    
    private func getVisibleInterval() -> DateInterval? {
        let metrics = TimelineMetrics(config: config)
        let orientation: TimelineOrientation = timelineVisibleSize.width > timelineVisibleSize.height ? .horizontal : .vertical
        let axisLength = orientation == .vertical ? timelineVisibleSize.height : timelineVisibleSize.width
        guard axisLength > 0 else { return nil }
        
        return metrics.dateInterval(for: -scrollPosition, length: axisLength, at: zoomScale)
    }

    private func programmaticallyScroll(toDate date: Date) {
        isScrollingProgrammatically = true
        withAnimation(.snappy) { centerDate = date }
    }

    private func scrollToNextEvent() {
        guard let visibleInterval = getVisibleInterval() else { return }
        let nextEvent = events.first { $0.startDate > visibleInterval.end }
        if let event = nextEvent {
            programmaticallyScroll(toDate: event.startDate)
        }
    }

    private func scrollToPreviousEvent() {
        guard let visibleInterval = getVisibleInterval() else { return }
        let previousEvent = events.last { $0.startDate < visibleInterval.start }
        if let event = previousEvent {
            programmaticallyScroll(toDate: event.startDate)
        }
    }
    
    private func updateCenterDateFromScroll(position: CGFloat) {
        let metrics = TimelineMetrics(config: config)
        let orientation: TimelineOrientation = timelineVisibleSize.width > timelineVisibleSize.height ? .horizontal : .vertical
        let axisLength = orientation == .vertical ? timelineVisibleSize.height : timelineVisibleSize.width
        guard axisLength > 0 else { return }
        
        let newCenterDate = metrics.date(at: -position + (axisLength / 2), for: zoomScale)
        self.centerDate = newCenterDate
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
    let displaySettings: DisplaySettings
    let orientation: TimelineOrientation
    let visibleSize: CGSize
    
    @Binding var eventToEdit: Event?
    @Binding var zoomScale: CGFloat
    @Binding var centerDate: Date?
    @Binding var scrollPosition: CGFloat
    @Binding var isScrollingProgrammatically: Bool
    
    let onEventMoved: (Event, Date) -> Void
    let onTapDate: (Date) -> Void
    
    private var metrics: TimelineMetrics { TimelineMetrics(config: config) }

    var body: some View {
        Group {
            if events.isEmpty && config.isConfigured {
                TimelineNoEventsView(
                    metrics: metrics,
                    displaySettings: displaySettings,
                    orientation: orientation,
                    visibleSize: visibleSize,
                    zoomScale: $zoomScale,
                    scrollPosition: $scrollPosition,
                    onTapDate: onTapDate
                )
            } else if let centerDateBinding = Binding($centerDate) {
                TimelineScrollView(
                    events: events,
                    metrics: metrics,
                    displaySettings: displaySettings,
                    orientation: orientation,
                    visibleSize: visibleSize,
                    zoomScale: $zoomScale,
                    centerDate: centerDateBinding,
                    scrollPosition: $scrollPosition,
                    isScrollingProgrammatically: $isScrollingProgrammatically,
                    eventToEdit: $eventToEdit,
                    isDragEnabled: displaySettings.isDragEnabled,
                    onEventMoved: onEventMoved,
                    onTapDate: onTapDate
                )
            } else {
                Color.clear
            }
        }
    }
}

struct TimelineNoEventsView: View {
    let metrics: TimelineMetrics
    let displaySettings: DisplaySettings
    let orientation: TimelineOrientation
    let visibleSize: CGSize
    @Binding var zoomScale: CGFloat
    @Binding var scrollPosition: CGFloat
    let onTapDate: (Date) -> Void
    
    var body: some View {
        ZStack {
            TimelineBackground(
                metrics: metrics,
                displaySettings: displaySettings,
                zoomScale: zoomScale,
                orientation: orientation,
                axisSize: 60,
                visibleSize: visibleSize,
                scrollPosition: $scrollPosition,
                events: [],
                onTapDate: onTapDate
            )
            ContentUnavailableView("No Events Yet", systemImage: "note.text.badge.plus", description: Text("Tap the + button or tap on the timeline to add your first event."))
        }
    }
}

struct TimelineScrollView: View {
    let events: [Event]
    let metrics: TimelineMetrics
    let displaySettings: DisplaySettings
    let orientation: TimelineOrientation
    let visibleSize: CGSize
    
    @Binding var zoomScale: CGFloat
    @Binding var centerDate: Date
    @Binding var scrollPosition: CGFloat
    @Binding var isScrollingProgrammatically: Bool
    @Binding var eventToEdit: Event?
    
    let isDragEnabled: Bool
    let onEventMoved: (Event, Date) -> Void
    let onTapDate: (Date) -> Void

    private struct DragState {
        let event: Event
        let originalStartDate: Date
    }
    
    @State private var dragState: DragState?
    @State private var initialZoomScale: CGFloat?
    
    private let axisSize: CGFloat = 60
    private let maxZoomScale: CGFloat = 200.0
    private let scrollCoordinateSpace = "scroll"
    private let contentID = "timelineContent"
    
    private var layouts: [LayoutEvent] {
        let crossAxisSize = orientation == .vertical ? visibleSize.width - axisSize : visibleSize.height - axisSize
        return generateLayouts(containerCrossAxisSize: crossAxisSize, draggedEventID: dragState?.event.id)
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
                    
                    TimelineBackground(
                        metrics: metrics,
                        displaySettings: displaySettings,
                        zoomScale: zoomScale,
                        orientation: orientation,
                        axisSize: axisSize,
                        visibleSize: visibleSize,
                        scrollPosition: $scrollPosition,
                        events: events,
                        onTapDate: onTapDate
                    )
                    
                    ForEach(events.filter { $0.isArcEvent && $0.isDuration }) { arcEvent in
                        let startPos = metrics.position(for: arcEvent.startDate, at: zoomScale)
                        let length = metrics.pureLength(for: arcEvent.effectiveDuration, at: zoomScale)
                        
                        if length > 0.5 {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(
                                    width: orientation == .vertical ? axisSize : length,
                                    height: orientation == .vertical ? length : axisSize
                                )
                                .offset(
                                    x: orientation == .vertical ? 0 : startPos,
                                    y: orientation == .vertical ? startPos : 0
                                )
                                .onTapGesture { eventToEdit = arcEvent }
                                .if(isDragEnabled) { view in
                                    view.gesture(dragGesture(for: arcEvent))
                                }
                        }
                    }
                    
                    ForEach(layouts) { layout in
                        let isBeingDragged = dragState?.event.id == layout.id
                        
                        EventView(event: layout.event, orientation: orientation, displaySettings: displaySettings)
                            .frame(width: layout.frame.width, height: layout.frame.height)
                            .offset(x: layout.frame.minX, y: layout.frame.minY)
                            .scaleEffect(isBeingDragged ? 1.05 : 1.0)
                            .opacity(isBeingDragged ? 0.75 : 1.0)
                            .zIndex(isBeingDragged ? 1 : 0)
                            .if(!layout.event.isArcEvent) { view in
                                view.onTapGesture { eventToEdit = layout.event }
                            }
                            .if(isDragEnabled && !layout.event.isArcEvent) { view in
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
            .onChange(of: centerDate) { _, newDate in
                if isScrollingProgrammatically {
                    scrollTo(date: newDate, proxy: proxy, animated: true)
                }
            }
        }
    }
    
    private func scrollTo(date: Date, proxy: ScrollViewProxy, animated: Bool) {
        let axisLength = orientation == .vertical ? visibleSize.height : visibleSize.width
        guard axisLength > 0 else { return }

        let totalLength = orientation == .vertical ? contentSize.height : contentSize.width
        guard totalLength > 0 else { return }

        let targetPosition = metrics.position(for: date, at: zoomScale)
        let desiredOffset = targetPosition - (axisLength / 2)
        let maxOffset = totalLength - axisLength
        let clampedOffset = max(0, min(desiredOffset, max(0, maxOffset)))
        
        let anchor = orientation == .vertical
            ? UnitPoint(x: 0, y: clampedOffset / totalLength)
            : UnitPoint(x: clampedOffset / totalLength, y: 0)
        
        let scrollAction = {
            proxy.scrollTo(contentID, anchor: anchor)
        }
        
        if animated {
            withAnimation(.snappy) { scrollAction() }
        } else {
            scrollAction()
        }
    }
    
    private func magnificationGesture(proxy: ScrollViewProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard dragState == nil else { return }
                
                let visibleLength = orientation == .vertical ? visibleSize.height : visibleSize.width
                guard visibleLength > 0 else { return }
                
                isScrollingProgrammatically = true

                let dateAtCenter = metrics.date(at: -scrollPosition + (visibleLength / 2), for: zoomScale)
                
                if initialZoomScale == nil { initialZoomScale = zoomScale }
                if let initial = initialZoomScale {
                    zoomScale = max(calculateMinZoom(), min(maxZoomScale, initial * value))
                }
                
                scrollTo(date: dateAtCenter, proxy: proxy, animated: false)
            }
            .onEnded { _ in
                initialZoomScale = nil
                isScrollingProgrammatically = false
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
    
    private func calculateVisualRect(for event: Event) -> CGRect {
        let startPos = metrics.position(for: event.startDate, at: zoomScale)
        let minPoints = orientation == .horizontal ? 180.0 : 44.0
        let length = max(metrics.pureLength(for: event.effectiveDuration, at: zoomScale), minPoints)
        return orientation == .vertical ? CGRect(x: 0, y: startPos, width: 1, height: length) : CGRect(x: startPos, y: 0, width: length, height: 1)
    }

    private func generateLayouts(containerCrossAxisSize: CGFloat, draggedEventID: ObjectIdentifier?) -> [LayoutEvent] {
        var layouts: [LayoutEvent] = []
        
        let arcEvents = events.filter { $0.isArcEvent }
        let regularEvents = events.filter { !$0.isArcEvent }

        // 1. Layout Arc Events
        let hasArcLane = !arcEvents.isEmpty
        let arcLaneSize: CGFloat = 10.0
        for event in arcEvents {
            let startPos = metrics.position(for: event.startDate, at: zoomScale)
            let length = metrics.pureLength(for: event.effectiveDuration, at: zoomScale)
            let frame: CGRect
            if orientation == .vertical {
                frame = CGRect(x: axisSize, y: startPos, width: arcLaneSize, height: max(1, length))
            } else {
                frame = CGRect(x: startPos, y: axisSize, width: max(1, length), height: arcLaneSize)
            }
            layouts.append(LayoutEvent(event: event, frame: frame))
        }

        // 2. Layout Regular Events
        let regularContainerSize = containerCrossAxisSize - (hasArcLane ? arcLaneSize : 0)
        let regularContainerOffset = axisSize + (hasArcLane ? arcLaneSize : 0)
        
        var remainingEvents = regularEvents
        while !remainingEvents.isEmpty {
            var group: [Event] = []
            var queue: [Event] = [remainingEvents.removeFirst()]
            group.append(queue.first!)

            while !queue.isEmpty {
                let current = queue.removeFirst()
                let currentRect = calculateVisualRect(for: current)
                
                let intersecting = remainingEvents.filter {
                    let otherRect = calculateVisualRect(for: $0)
                    return currentRect.intersects(otherRect)
                }
                
                for event in intersecting {
                    group.append(event)
                    queue.append(event)
                }
                remainingEvents.removeAll { intersecting.contains($0) }
            }
            
            var laneVisualRects: [Int: [CGRect]] = [:]
            var eventLanes: [ObjectIdentifier: Int] = [:]
            var eventsToProcess = group

            if let draggedEventID = draggedEventID,
               let draggedEventIndex = eventsToProcess.firstIndex(where: { $0.id == draggedEventID }) {
                let draggedEvent = eventsToProcess.remove(at: draggedEventIndex)
                eventLanes[draggedEvent.id] = 0
                laneVisualRects[0, default: []].append(calculateVisualRect(for: draggedEvent))
            }
            
            for event in eventsToProcess.sorted(by: { $0.startDate < $1.startDate }) {
                let visualRect = calculateVisualRect(for: event)
                var assignedLane = 0
                while true {
                    if let rectsInLane = laneVisualRects[assignedLane], rectsInLane.contains(where: { $0.intersects(visualRect) }) {
                        assignedLane += 1
                    } else {
                        eventLanes[event.id] = assignedLane
                        laneVisualRects[assignedLane, default: []].append(visualRect)
                        break
                    }
                }
            }
            
            let totalLanes = (laneVisualRects.keys.max() ?? -1) + 1
            let laneSize = totalLanes > 0 ? max(44, regularContainerSize / CGFloat(totalLanes)) : regularContainerSize
            
            for event in group {
                guard let laneIndex = eventLanes[event.id] else { continue }
                
                let startPos = metrics.position(for: event.startDate, at: zoomScale)
                let minPoints = orientation == .horizontal ? 180.0 : 44.0
                let mainAxisLength = max(metrics.pureLength(for: event.effectiveDuration, at: zoomScale), minPoints)
                
                let crossAxisLaneOffset = CGFloat(laneIndex) * laneSize
                let crossAxisStart = regularContainerOffset + crossAxisLaneOffset
                
                let frame: CGRect
                if orientation == .vertical {
                    frame = CGRect(x: crossAxisStart, y: startPos, width: laneSize, height: mainAxisLength)
                } else {
                    frame = CGRect(x: startPos, y: crossAxisStart, width: mainAxisLength, height: laneSize)
                }
                layouts.append(LayoutEvent(event: event, frame: frame))
            }
        }
        
        return layouts
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
    let metrics: TimelineMetrics
    let displaySettings: DisplaySettings
    let zoomScale: CGFloat
    let orientation: TimelineOrientation
    let axisSize: CGFloat
    let visibleSize: CGSize
    @Binding var scrollPosition: CGFloat
    let events: [Event]
    let onTapDate: (Date) -> Void
    
    @State private var renderableRegion = RenderableRegion()
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard displaySettings.isTapToAddEnabled else { return }
                    
                    let crossAxisLocation = orientation == .vertical ? location.x : location.y
                    guard crossAxisLocation > axisSize else { return }
                    
                    let mainAxisLocation = orientation == .vertical ? location.y : location.x
                    let date = metrics.date(at: mainAxisLocation, for: zoomScale)
                    onTapDate(date)
                }

            Rectangle().fill(.tertiary.opacity(0.5))
                .frame(width: orientation == .vertical ? 1:nil, height: orientation == .horizontal ? 1:nil)
                .offset(x: orientation == .vertical ? axisSize-1:0, y: orientation == .horizontal ? axisSize-1:0)

            ForEach(renderableRegion.markers, id: \.date) { marker in
                let pos = metrics.position(for: marker.date, at: zoomScale)
                let tickSize: CGFloat = marker.isMajor ? 10 : 5
                
                if orientation == .vertical {
                    Path { p in p.move(to: CGPoint(x: axisSize - tickSize, y: pos)); p.addLine(to: CGPoint(x: axisSize, y: pos)) }.stroke(.tertiary, lineWidth: 1)
                    Text(marker.label).font(marker.isMajor ? .caption.bold() : .caption).foregroundColor(.secondary).frame(width: axisSize - tickSize - 4, alignment: .trailing).position(x: (axisSize - tickSize - 4) / 2, y: pos)
                } else {
                    Path { p in p.move(to: CGPoint(x: pos, y: axisSize - tickSize)); p.addLine(to: CGPoint(x: pos, y: axisSize)) }.stroke(.tertiary, lineWidth: 1)
                    Text(marker.label).font(marker.isMajor ? .caption.bold() : .caption).foregroundColor(.secondary).frame(width: 50).position(x: pos, y: (axisSize - tickSize - 12) / 2)
                }
            }
            
            ForEach(renderableRegion.events) { event in
                let startPos = metrics.position(for: event.startDate, at: zoomScale)
                if event.isDuration {
                    let markerLength = event.effectiveDuration * metrics.pointsPerSecond(at: zoomScale)
                    if markerLength > 0.5 {
                        Capsule().fill(event.color.opacity(0.7)).frame(width: orientation == .vertical ? 4 : markerLength, height: orientation == .vertical ? markerLength : 4).offset(x: orientation == .vertical ? axisSize-12 : startPos, y: orientation == .vertical ? startPos : axisSize-12)
                    }
                } else {
                    Circle().fill(event.color).frame(width: 6, height: 6).position(x: orientation == .vertical ? axisSize-10 : startPos, y: orientation == .vertical ? startPos : axisSize-10)
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
            if debounced { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled else { return }
            let visibleLength = orientation == .vertical ? visibleSize.height : visibleSize.width
            guard visibleLength > 0 else { return }
            let visibleInterval = metrics.dateInterval(for: -scrollPosition, length: visibleLength, at: zoomScale)
            let bufferDuration = visibleInterval.duration * 4.0
            let bufferedInterval = DateInterval(start: visibleInterval.start.addingTimeInterval(-bufferDuration), end: visibleInterval.end.addingTimeInterval(bufferDuration))
            let newMarkers = getMarkers(for: bufferedInterval)
            let newEvents = events.filter {
                let eventInterval = DateInterval(start: $0.startDate, duration: $0.effectiveDuration)
                return bufferedInterval.intersects(eventInterval)
            }
            await MainActor.run { renderableRegion = RenderableRegion(markers: newMarkers, events: newEvents) }
        }
        self.debounceTask = newRenderTask
    }
    
    private func getMarkers(for visibleInterval: DateInterval) -> [(date: Date, label: String, isMajor: Bool)] {
        var markers: [(Date, String, Bool)] = []
        let calendar = Calendar.current
        let minMarkerSpacing: CGFloat = 80.0
        let unit: Calendar.Component, step: Int, minorFormat: Date.FormatStyle, majorFormat: Date.FormatStyle, majorUnit: Calendar.Component
        let pps = metrics.pointsPerSecond(at: zoomScale)
        if pps * 3600 > minMarkerSpacing { unit = .hour; step = 1; minorFormat = .dateTime.hour(); majorFormat = .dateTime.hour().day(.defaultDigits).month(.abbreviated); majorUnit = .day
        } else if pps * 86400 > minMarkerSpacing { unit = .day; step = 1; minorFormat = .dateTime.day(); majorFormat = .dateTime.month(.abbreviated).day(); majorUnit = .month
        } else if pps * 86400 * 7 > minMarkerSpacing { unit = .day; step = 7; minorFormat = .dateTime.day(); majorFormat = .dateTime.month(.abbreviated).day(); majorUnit = .month
        } else if pps * 86400 * 30.44 > minMarkerSpacing { unit = .month; step = 1; minorFormat = .dateTime.month(.abbreviated); majorFormat = .dateTime.year().month(.abbreviated); majorUnit = .year
        } else { unit = .year; step = 1; minorFormat = .dateTime.year(); majorFormat = .dateTime.year(); majorUnit = .year }
        guard var currentDate = calendar.dateInterval(of: unit, for: visibleInterval.start)?.start else { return [] }
        if unit == .day, step == 7 { currentDate = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: currentDate)) ?? currentDate }
        while currentDate <= visibleInterval.end {
            let majorUnitValue = calendar.component(majorUnit, from: currentDate)
            let prevDate = calendar.date(byAdding: .second, value: -1, to: currentDate)!
            let prevMajorUnitValue = calendar.component(majorUnit, from: prevDate)
            let isMajor = majorUnitValue != prevMajorUnitValue
            let label = currentDate.formatted(isMajor ? majorFormat : minorFormat)
            markers.append((currentDate, label, isMajor))
            guard let nextDate = calendar.date(byAdding: unit, value: step, to: currentDate) else { break }
            currentDate = nextDate
        }
        return markers
    }
}
struct EventView: View {
    let event: Event
    let orientation: TimelineOrientation
    let displaySettings: DisplaySettings
    
    var body: some View {
        Group {
            if event.isArcEvent {
                arcBody
            } else {
                standardBody
            }
        }
    }
    
    private var arcBody: some View {
        RoundedRectangle(cornerRadius: 4).fill(event.color)
    }
    
    private var standardBody: some View {
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
            if displaySettings.showTitle { Text(event.title).font(.system(size: 14, weight: .bold)).lineLimit(2) }
            Text(dateString()).font(.caption).foregroundColor(.secondary).lineLimit(2)
            if displaySettings.showDetails, !event.details.isEmpty { Text(event.details).font(.caption).foregroundColor(.secondary).padding(.top, 2).lineLimit(4) }
            if displaySettings.showPeople { peopleList }
            if displaySettings.showLocations { locationList }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var horizontalBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            if displaySettings.showTitle { Text(event.title).font(.system(size: 14, weight: .bold)).lineLimit(2) }
            Text(dateString()).font(.caption).foregroundColor(.secondary).lineLimit(2)
            if displaySettings.showDetails, !event.details.isEmpty { Text(event.details).font(.caption).foregroundColor(.secondary.opacity(0.8)).padding(.top, 2).lineLimit(3) }
            if displaySettings.showPeople { peopleList.padding(.top, 2) }
            if displaySettings.showLocations { locationList }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    @ViewBuilder private var peopleList: some View {
        if let people = event.people, !people.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(people.sorted(by: { $0.name < $1.name })) { person in Label(person.name, systemImage: "person.fill").font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(Color.secondary.opacity(0.2)).clipShape(Capsule()) }
                }
            }.padding(.top, 4)
        }
    }
    
    @ViewBuilder private var locationList: some View {
        if let locations = event.locations, !locations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(locations.sorted(by: { $0.name < $1.name })) { location in Label(location.name, systemImage: "mappin.and.ellipse").font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(Color.secondary.opacity(0.2)).clipShape(Capsule()) }
                }
            }.padding(.top, 2)
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
struct ScrollToDateView: View {
    @Environment(\.dismiss) var dismiss
    let timelineRange: ClosedRange<Date>
    let onDateSelected: (Date) -> Void
    
    @State private var selectedDate: Date
    
    init(timelineRange: ClosedRange<Date>, onDateSelected: @escaping (Date) -> Void) {
        self.timelineRange = timelineRange
        self.onDateSelected = onDateSelected
        _selectedDate = State(initialValue: timelineRange.lowerBound)
    }

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker("Select Date", selection: $selectedDate, in: timelineRange, displayedComponents: .date).datePickerStyle(.graphical).padding()
                Button("Go to Date") { onDateSelected(selectedDate) }.buttonStyle(.borderedProminent)
            }
            .navigationTitle("Go to Date").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct TimelineSettingsView: View {
    @Bindable var config: TimelineConfiguration
    @Bindable var displaySettings: DisplaySettings
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Timeline Range") {
                    DatePicker("Start Date", selection: $config.startDate, displayedComponents: .date)
                    DatePicker("End Date", selection: $config.endDate, displayedComponents: .date)
                }
                
                Section("Display & Interaction") {
                    Toggle("Enable Dragging", isOn: $displaySettings.isDragEnabled)
                    Toggle("Tap to Add New Event", isOn: $displaySettings.isTapToAddEnabled)
                    Toggle("Show Title", isOn: $displaySettings.showTitle)
                    Toggle("Show Details", isOn: $displaySettings.showDetails)
                    Toggle("Show People", isOn: $displaySettings.showPeople)
                    Toggle("Show Locations", isOn: $displaySettings.showLocations)
                }
            }
            .navigationTitle("Timeline Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        config.save()
                        displaySettings.save()
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
    
    @Query(sort: \Person.name) private var allPeople: [Person]
    @Query(sort: \Location.name) private var allLocations: [Location]
    
    var event: Event?
    let timelineRange: ClosedRange<Date>
    var initialDate: Date? = nil
    
    @State private var title: String = ""
    @State private var details: String = ""
    @State private var startDate: Date = .now
    @State private var endDate: Date? = nil
    @State private var precision: TimePrecision = .day
    @State private var isArcEvent: Bool = false
    @State private var showDeleteConfirmation = false
    
    @State private var colorHex: String?
    @State private var customColor: Color = .accentColor
    
    @State private var selectedPeople = Set<Person>()
    @State private var selectedLocations = Set<Location>()
    
    @State private var showAddPersonAlert = false
    @State private var newPersonName = ""
    @State private var showAddLocationAlert = false
    @State private var newLocationName = ""
    
    private let presetColors: [ColorChoice] = ColorChoice.presets
    
    private var unselectedPeople: [Person] { allPeople.filter { !selectedPeople.contains($0) } }
    private var unselectedLocations: [Location] { allLocations.filter { !selectedLocations.contains($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) }
                
                Section("Look") {
                    Toggle("Arc Event", isOn: $isArcEvent.animation())
                    HStack(spacing: 16) {
                        ForEach(presetColors) { choice in
                            Circle().fill(choice.color).frame(width: 30, height: 30).overlay(Circle().stroke(Color.primary, lineWidth: colorHex == choice.id ? 2 : 0)).onTapGesture { colorHex = choice.id; customColor = choice.color }
                        }
                        ColorPicker("", selection: $customColor, supportsOpacity: false).labelsHidden()
                    }
                    if colorHex != nil { Button("Clear Color", role: .destructive) { colorHex = nil; customColor = .accentColor } }
                }
                
                if !isArcEvent {
                    Section("Precision") {
                        Picker("Precision", selection: $precision.animation()) {
                            ForEach(TimePrecision.allCases, id: \.self) { p in Text(p.description).tag(p) }
                        }.pickerStyle(.segmented)
                    }
                }
                
                Section("Start") { DatePicker("Date", selection: $startDate, in: timelineRange, displayedComponents: precision == .time && !isArcEvent ? [.date, .hourAndMinute] : [.date]) }
                
                Section("End") {
                    if let binding = Binding($endDate) {
                        DatePicker("Date", selection: binding, in: startDate..., displayedComponents: precision == .time && !isArcEvent ? [.date, .hourAndMinute] : [.date])
                        Button("Remove End Date", role: .destructive) { endDate = nil }
                    } else {
                        Button("Add End Date") { endDate = startDate.addingTimeInterval(3600) }
                    }
                }
                
                if !isArcEvent {
                    Group {
                        Section("People") {
                            ForEach(Array(selectedPeople).sorted(by: { $0.name < $1.name })) { person in HStack { Text(person.name); Spacer(); Button { selectedPeople.remove(person) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) } }.buttonStyle(.borderless) }
                            Menu("Add Person") {
                                if !unselectedPeople.isEmpty { ForEach(unselectedPeople) { p in Button(p.name) { selectedPeople.insert(p) } }; Divider() }
                                Button("Add New Person...") { newPersonName = ""; showAddPersonAlert = true }
                            }
                        }
                        
                        Section("Locations") {
                            ForEach(Array(selectedLocations).sorted(by: { $0.name < $1.name })) { location in HStack { Text(location.name); Spacer(); Button { selectedLocations.remove(location) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) } }.buttonStyle(.borderless) }
                            Menu("Add Location") {
                                if !unselectedLocations.isEmpty { ForEach(unselectedLocations) { l in Button(l.name) { selectedLocations.insert(l) } }; Divider() }
                                Button("Add New Location...") { newLocationName = ""; showAddLocationAlert = true }
                            }
                        }
                        Section("Description") { TextEditor(text: $details).frame(minHeight: 120) }
                    }
                }
                
                if event != nil { Section { Button("Delete Event", role: .destructive) { showDeleteConfirmation = true } } }
            }
            .navigationTitle(event == nil ? "New Event" : "Edit Event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(title.isEmpty) }
            }
            .onAppear(perform: setupInitialState)
            .onChange(of: customColor) { _, newColor in colorHex = newColor.toHex() }
            .onChange(of: isArcEvent) { _, newIsArc in if newIsArc { precision = .day } }
            .alert("Delete Event?", isPresented: $showDeleteConfirmation) { Button("Delete", role: .destructive, action: deleteEvent); Button("Cancel", role: .cancel) {} } message: { Text("This action cannot be undone.") }
            .alert("New Person", isPresented: $showAddPersonAlert) { TextField("Name", text: $newPersonName); Button("Add", action: createAndSelectPerson).disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty); Button("Cancel", role: .cancel) {} }
            .alert("New Location", isPresented: $showAddLocationAlert) { TextField("Name", text: $newLocationName); Button("Add", action: createAndSelectLocation).disabled(newLocationName.trimmingCharacters(in: .whitespaces).isEmpty); Button("Cancel", role: .cancel) {} }
        }
    }
    
    private func setupInitialState() {
        if let event {
            title = event.title; details = event.details; startDate = event.startDate; endDate = event.endDate; precision = event.precision; colorHex = event.colorHex; isArcEvent = event.isArcEvent
            selectedPeople = Set(event.people ?? []); selectedLocations = Set(event.locations ?? [])
            customColor = Color(hex: colorHex) ?? .accentColor
        } else {
            let date = initialDate ?? Calendar.current.date(byAdding: .day, value: 1, to: timelineRange.lowerBound) ?? .now
            startDate = timelineRange.contains(date) ? date : timelineRange.lowerBound
        }
    }
    
    private func save() {
        let calendar = Calendar.current
        let finalPrecision = isArcEvent ? .day : precision
        let finalStartDate = finalPrecision == .day ? calendar.startOfDay(for: startDate) : startDate
        var finalEndDate: Date?
        if let currentEndDate = endDate { finalEndDate = finalPrecision == .day ? calendar.startOfDay(for: currentEndDate) : currentEndDate }

        if let event {
            event.title = title; event.details = isArcEvent ? "" : details; event.startDate = finalStartDate; event.endDate = finalEndDate; event.precision = finalPrecision; event.colorHex = colorHex; event.isArcEvent = isArcEvent
            event.people = isArcEvent ? [] : Array(selectedPeople); event.locations = isArcEvent ? [] : Array(selectedLocations)
        } else {
            let newEvent = Event(startDate: finalStartDate, endDate: finalEndDate, title: title, details: isArcEvent ? "" : details, precision: finalPrecision, colorHex: colorHex, isArcEvent: isArcEvent)
            newEvent.people = isArcEvent ? [] : Array(selectedPeople); newEvent.locations = isArcEvent ? [] : Array(selectedLocations)
            modelContext.insert(newEvent)
        }
        dismiss()
    }
    
    private func deleteEvent() { if let event { modelContext.delete(event) }; dismiss() }
    private func createAndSelectPerson() { let name = newPersonName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }; let p = Person(name: name); modelContext.insert(p); selectedPeople.insert(p) }
    private func createAndSelectLocation() { let name = newLocationName.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }; let l = Location(name: name); modelContext.insert(l); selectedLocations.insert(l) }
}


// MARK: - Color Helpers

struct ColorChoice: Identifiable, Hashable {
    let id: String, color: Color
    static let presets: [ColorChoice] = [ .init(id: "#5792F2", color: .blue), .init(id: "#4CAF50", color: .green), .init(id: "#FFC107", color: .yellow), .init(id: "#FF9800", color: .orange), .init(id: "#F44336", color: .red), .init(id: "#9C27B0", color: .purple), .init(id: "#607D8B", color: .gray) ]
}

extension Color {
    init?(hex: String?) {
        guard var hex = hex else { return nil }
        hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0; Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: return nil
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
    
    func toHex() -> String? {
        let uic = UIColor(self)
        guard let components = uic.cgColor.components, components.count >= 3 else { return nil }
        let r = Float(components[0]); let g = Float(components[1]); let b = Float(components[2])
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

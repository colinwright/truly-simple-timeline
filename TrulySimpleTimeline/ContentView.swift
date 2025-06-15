import SwiftUI
import SwiftData

// MARK: - Models

@Model
final class Timeline {
    var id: UUID = UUID()
    var name: String = ""
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    
    @Relationship(deleteRule: .cascade, inverse: \Event.timeline)
    var events: [Event]?
    
    init(name: String, startDate: Date, endDate: Date) {
        self.id = UUID()
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
    }
    
    var dateRange: ClosedRange<Date> {
        startDate...endDate
    }
}

extension Timeline: Equatable {
    static func == (lhs: Timeline, rhs: Timeline) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }
}

@Model
final class Person {
    var name: String = ""
    var events: [Event]?
    
    init(name: String) {
        self.name = name
    }
}

@Model
final class Location {
    var name: String = ""
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
    var startDate: Date = Date.now
    var endDate: Date?
    var title: String = ""
    var details: String = ""
    var precision: TimePrecision = TimePrecision.day
    var colorHex: String?
    var isArcEvent: Bool = false
    
    var timeline: Timeline?

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
class DisplaySettings {
    private let showTitleKey = "displayShowTitle"
    private let showDetailsKey = "displayShowDetails"
    private let showPeopleKey = "displayShowPeople"
    private let showLocationsKey = "displayShowLocations"
    private let showDurationKey = "displayShowDuration"
    private let isDragEnabledKey = "displayIsDragEnabled"
    private let isTapToAddEnabledKey = "displayIsTapToAddEnabled"
    private let constrainEventsToBoundsKey = "displayConstrainEventsToBounds"

    var showTitle: Bool
    var showDetails: Bool
    var showPeople: Bool
    var showLocations: Bool
    var showDuration: Bool
    var isDragEnabled: Bool
    var isTapToAddEnabled: Bool
    var constrainEventsToBounds: Bool

    init() {
        let defaults = UserDefaults.standard
        self.showTitle = defaults.object(forKey: showTitleKey) as? Bool ?? true
        self.showDetails = defaults.object(forKey: showDetailsKey) as? Bool ?? true
        self.showPeople = defaults.object(forKey: showPeopleKey) as? Bool ?? true
        self.showLocations = defaults.object(forKey: showLocationsKey) as? Bool ?? true
        self.showDuration = defaults.object(forKey: showDurationKey) as? Bool ?? true
        self.isDragEnabled = defaults.object(forKey: isDragEnabledKey) as? Bool ?? true
        self.isTapToAddEnabled = defaults.object(forKey: isTapToAddEnabledKey) as? Bool ?? true
        self.constrainEventsToBounds = defaults.object(forKey: constrainEventsToBoundsKey) as? Bool ?? true
    }
    
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(showTitle, forKey: showTitleKey)
        defaults.set(showDetails, forKey: showDetailsKey)
        defaults.set(showPeople, forKey: showPeopleKey)
        defaults.set(showLocations, forKey: showLocationsKey)
        defaults.set(showDuration, forKey: showDurationKey)
        defaults.set(isDragEnabled, forKey: isDragEnabledKey)
        defaults.set(isTapToAddEnabled, forKey: isTapToAddEnabledKey)
        defaults.set(constrainEventsToBounds, forKey: constrainEventsToBoundsKey)
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

    func performUndo(context: ModelContext) {
        guard let action = undoStack.popLast() else { return }
        
        switch action {
        case .move(let eventID, let fromDate, let toDate):
            if let event = findEvent(by: eventID, in: context) {
                applyMove(to: event, newDate: fromDate)
                let redoAction = Action.move(eventID: eventID, from: fromDate, to: toDate)
                redoStack.append(redoAction)
            }
        }
    }

    func performRedo(context: ModelContext) {
        guard let action = redoStack.popLast() else { return }
        
        switch action {
        case .move(let eventID, let fromDate, let toDate):
            if let event = findEvent(by: eventID, in: context) {
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

    private func findEvent(by id: PersistentIdentifier, in context: ModelContext) -> Event? {
        context.model(for: id) as? Event
    }
    
    private func applyMove(to event: Event, newDate: Date) {
        let duration = event.duration
        event.startDate = newDate
        if event.isDuration {
            event.endDate = newDate.addingTimeInterval(duration)
        }
    }
}


// MARK: - Root View & Timeline Management

struct ContentView: View {
    @Query(sort: \Timeline.name) private var timelines: [Timeline]
    @State private var activeTimeline: Timeline?
    @State private var showTimelineSelector = false
    @State private var showNewTimelineSheet = false

    private let lastActiveTimelineKey = "lastActiveTimelineID"

    var body: some View {
        Group {
            if let activeTimeline {
                TimelineDetailView(timeline: activeTimeline, showTimelineSelector: $showTimelineSelector)
            } else {
                NoTimelinesView(showNewTimelineSheet: $showNewTimelineSheet)
            }
        }
        .onAppear(perform: loadInitialTimeline)
        .onChange(of: timelines) { _, _ in loadInitialTimeline() }
        .onChange(of: activeTimeline) { _, newValue in saveActiveTimeline(newValue: newValue) }
        .sheet(isPresented: $showTimelineSelector) {
            TimelineSelectorView(activeTimeline: $activeTimeline)
        }
        .sheet(isPresented: $showNewTimelineSheet) {
            TimelineEditorView { newTimeline in
                self.activeTimeline = newTimeline
            }
        }
    }

    private func loadInitialTimeline() {
        if !timelines.isEmpty && activeTimeline == nil {
            if let idString = UserDefaults.standard.string(forKey: lastActiveTimelineKey),
               let id = UUID(uuidString: idString),
               let lastUsed = timelines.first(where: { $0.id == id }) {
                activeTimeline = lastUsed
            } else {
                activeTimeline = timelines.first
            }
        } else if timelines.isEmpty {
            activeTimeline = nil
        }
    }
    
    private func saveActiveTimeline(newValue: Timeline?) {
        if let newID = newValue?.id.uuidString {
            UserDefaults.standard.set(newID, forKey: lastActiveTimelineKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastActiveTimelineKey)
        }
    }
}

struct NoTimelinesView: View {
    @Binding var showNewTimelineSheet: Bool
    
    var body: some View {
        ZStack {
            #if os(iOS)
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            #else
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            #endif
            VStack(spacing: 12) {
                Text("No Timelines")
                    .font(.title.bold())
                Text("Create a timeline to get started.")
                    .foregroundStyle(.secondary)
                Button("Create New Timeline") {
                    showNewTimelineSheet = true
                }
                .buttonStyle(.borderedProminent)
                .padding(.top)
            }
            .padding()
        }
    }
}

fileprivate struct NewEventRequest: Identifiable {
    let id = UUID()
    let date: Date
}

struct TimelineDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let timeline: Timeline
    @Binding var showTimelineSelector: Bool
    
    @Query private var events: [Event]

    @State private var displaySettings = DisplaySettings()
    @State private var showDisplaySettings = false
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
    
    private struct TimelineDependencies: Equatable {
        let id: UUID
        let startDate: Date
        let endDate: Date
    }

    private var timelineDependencies: TimelineDependencies {
        TimelineDependencies(id: timeline.id, startDate: timeline.startDate, endDate: timeline.endDate)
    }
    
    init(timeline: Timeline, showTimelineSelector: Binding<Bool>) {
        self.timeline = timeline
        self._showTimelineSelector = showTimelineSelector
        
        let timelineID = timeline.persistentModelID
        self._events = Query(filter: #Predicate { $0.timeline?.persistentModelID == timelineID }, sort: \Event.startDate)
    }

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
                
                TimelineView(
                    events: events,
                    timeline: timeline,
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
                .onAppear { timelineVisibleSize = geometry.size }
                .onChange(of: geometry.size) { _, newSize in timelineVisibleSize = newSize }
                .navigationTitle(timeline.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    // This group is for leading items on iOS and general items on macOS
                    ToolbarItemGroup(placement: .principal) {
                        Button { showTimelineSelector = true } label: { Image(systemName: "list.bullet") }
                        
                        Button("Undo", systemImage: "arrow.uturn.backward") { undoRedoManager.performUndo(context: modelContext) }
                            .disabled(!undoRedoManager.canUndo)
                        
                        Button("Redo", systemImage: "arrow.uturn.forward") { undoRedoManager.performRedo(context: modelContext) }
                            .disabled(!undoRedoManager.canRedo)
                    }
                    
                    // This group is for the bottom bar on iOS only
                    #if os(iOS)
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
                    #endif
                    
                    // This group is for trailing items on iOS and primary actions on macOS
                    ToolbarItemGroup(placement: .primaryAction) {
                        #if os(macOS)
                        // On macOS, place the "Go To" button here.
                        Button {
                            showGoToMenu = true
                        } label: {
                            Label("Go To", systemImage: "magnifyingglass")
                        }
                        .popover(isPresented: $showGoToMenu) {
                            goToMenuContent
                        }
                        #endif
                        
                        Button { showEventEditor = true } label: { Image(systemName: "plus") }
                        Button { showDisplaySettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                .task(id: timelineDependencies) {
                    let axisLength = orientation == .vertical ? geometry.size.height : geometry.size.width
                    guard axisLength > 0 else { return }
                    
                    undoRedoManager.clearHistory()
                    isScrollingProgrammatically = true
                    
                    let metrics = TimelineMetrics(timeline: timeline)
                    let totalDuration = timeline.endDate.timeIntervalSince(timeline.startDate)
                    
                    guard totalDuration > 0 else {
                        zoomScale = 1.0
                        centerDate = timeline.startDate
                        return
                    }
                    
                    let buffer = totalDuration * 0.1
                    let bufferedDuration = totalDuration + buffer
                    let fitZoom = axisLength / metrics.pureLength(for: bufferedDuration, at: 1.0)
                    
                    let threeDaysInSeconds = 86400.0 * 3
                    if totalDuration <= threeDaysInSeconds {
                        let desiredHourlySpacing: CGFloat = 100.0
                        let requiredPointsPerSecond = desiredHourlySpacing / 3600.0
                        let zoomForHours = requiredPointsPerSecond * 30.0
                        
                        zoomScale = max(fitZoom, zoomForHours)
                    } else {
                        zoomScale = fitZoom
                    }

                    centerDate = timeline.startDate.addingTimeInterval(totalDuration / 2.0)
                }
            }
            #if os(iOS)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar, .bottomBar)
            #endif
            .sheet(isPresented: $showDisplaySettings) { DisplaySettingsView(displaySettings: $displaySettings) }
            .sheet(isPresented: $showEventEditor) { EventEditorView(timeline: timeline, displaySettings: $displaySettings) }
            .sheet(item: $eventToEdit) { event in EventEditorView(event: event, timeline: timeline, displaySettings: $displaySettings) }
            .sheet(item: $newEventRequest) { request in
                EventEditorView(timeline: timeline, initialDate: request.date, displaySettings: $displaySettings)
            }
            .sheet(isPresented: $showScrollToDateView) {
                ScrollToDateView(timelineRange: timeline.dateRange) { date in
                    programmaticallyScroll(toDate: date)
                    showScrollToDateView = false
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
        let metrics = TimelineMetrics(timeline: timeline)
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
        let metrics = TimelineMetrics(timeline: timeline)
        let orientation: TimelineOrientation = timelineVisibleSize.width > timelineVisibleSize.height ? .horizontal : .vertical
        let axisLength = orientation == .vertical ? timelineVisibleSize.height : timelineVisibleSize.width
        guard axisLength > 0 else { return }
        
        let newCenterDate = metrics.date(at: -position + (axisLength / 2), for: zoomScale)
        self.centerDate = newCenterDate
    }
}

// MARK: - Timeline View & Components

struct TimelineView: View {
    let events: [Event]
    let timeline: Timeline
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
    
    private var metrics: TimelineMetrics { TimelineMetrics(timeline: timeline) }

    var body: some View {
        Group {
            if let centerDateBinding = Binding($centerDate) {
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
                    onEventMoved: onEventMoved,
                    onTapDate: onTapDate
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
    let displaySettings: DisplaySettings
    let orientation: TimelineOrientation
    let visibleSize: CGSize
    
    @Binding var zoomScale: CGFloat
    @Binding var centerDate: Date
    @Binding var scrollPosition: CGFloat
    @Binding var isScrollingProgrammatically: Bool
    @Binding var eventToEdit: Event?
    
    let onEventMoved: (Event, Date) -> Void
    let onTapDate: (Date) -> Void

    private struct GhostEventInfo {
        let event: Event
        let originalStartDate: Date
        let originalDuration: TimeInterval
        let layoutFrame: CGRect
    }

    @State private var layouts: [LayoutEvent] = []
    @State private var ghostEvent: GhostEventInfo?
    @State private var dragOffset: CGSize = .zero
    @State private var initialZoomScale: CGFloat?
    
    private let axisSize: CGFloat = 60
    private let maxZoomScale: CGFloat = 200.0
    private let scrollCoordinateSpace = "scroll"
    private let contentID = "timelineContent"
    
    private var contentSize: CGSize {
        let totalDuration = metrics.timeline.endDate.timeIntervalSince(metrics.timeline.startDate)
        let totalLength = metrics.pureLength(for: totalDuration, at: zoomScale)
        
        if orientation == .vertical {
            return CGSize(width: visibleSize.width, height: max(totalLength, visibleSize.height))
        } else {
            return CGSize(width: max(totalLength, visibleSize.width), height: visibleSize.height)
        }
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
                    
                    ForEach(layouts) { layout in
                        EventView(event: layout.event, orientation: orientation, displaySettings: displaySettings)
                            .frame(width: layout.frame.width, height: layout.frame.height)
                            .offset(x: layout.frame.minX, y: layout.frame.minY)
                            .opacity(ghostEvent?.event.id == layout.event.id ? 0 : 1)
                            .onTapGesture { eventToEdit = layout.event }
                            .if(displaySettings.isDragEnabled) { $0.gesture(dragGesture(for: layout.event, layout: layout)) }
                    }
                    
                    if let ghost = ghostEvent {
                        EventView(event: ghost.event, orientation: orientation, displaySettings: displaySettings)
                            .frame(width: ghost.layoutFrame.width, height: ghost.layoutFrame.height)
                            .offset(x: ghost.layoutFrame.minX, y: ghost.layoutFrame.minY)
                            .offset(dragOffset)
                            .scaleEffect(1.05)
                            .opacity(0.75)
                            .zIndex(1)
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height)
                .id(contentID)
            }
            .coordinateSpace(name: scrollCoordinateSpace)
            .scrollDisabled(ghostEvent != nil)
            .simultaneousGesture(magnificationGesture(proxy: proxy))
            .onAppear(perform: recalculateLayouts)
            .onChange(of: events) { _, _ in recalculateLayouts() }
            .onChange(of: zoomScale) { _, _ in recalculateLayouts() }
            .onChange(of: visibleSize) { _, _ in recalculateLayouts() }
            .onChange(of: centerDate) { _, newDate in
                if isScrollingProgrammatically { scrollTo(date: newDate, proxy: proxy, animated: true) }
            }
        }
    }
    
    private func scrollTo(date: Date, proxy: ScrollViewProxy, animated: Bool) {
        let axisLength = orientation == .vertical ? visibleSize.height : visibleSize.width
        guard axisLength > 0 else { return }

        let totalLength = orientation == .vertical ? contentSize.height : contentSize.width
        guard totalLength > axisLength else { return }

        let targetPosition = metrics.position(for: date, at: zoomScale)
        let desiredOffset = targetPosition - (axisLength / 2)
        let maxOffset = totalLength - axisLength
        
        let clampedOffset = max(0, min(desiredOffset, maxOffset))

        let anchorRatio = maxOffset > 0 ? clampedOffset / maxOffset : 0
        let anchor = orientation == .vertical
            ? UnitPoint(x: 0.5, y: anchorRatio)
            : UnitPoint(x: anchorRatio, y: 0.5)
        
        let scrollAction = { proxy.scrollTo(contentID, anchor: anchor) }
        
        if animated { withAnimation(.snappy) { scrollAction() } } else { scrollAction() }
    }
    
    private func magnificationGesture(proxy: ScrollViewProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard ghostEvent == nil else { return }
                
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
    
    private func dragGesture(for event: Event, layout: LayoutEvent) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(scrollCoordinateSpace))
                .onChanged { value in
                    if ghostEvent == nil {
                        ghostEvent = GhostEventInfo(
                            event: event,
                            originalStartDate: event.startDate,
                            originalDuration: event.duration,
                            layoutFrame: layout.frame
                        )
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                    }
                    self.dragOffset = value.translation
                }
                .onEnded { value in
                    guard let endedDrag = ghostEvent else { return }

                    let dragLength = orientation == .vertical ? value.translation.height : value.translation.width
                    let pps = metrics.pointsPerSecond(at: zoomScale)
                    guard pps > 0 else {
                        self.ghostEvent = nil
                        self.dragOffset = .zero
                        return
                    }

                    let timeOffset = dragLength / pps
                    let newStartDate = endedDrag.originalStartDate.addingTimeInterval(timeOffset)
                    
                    let eventToMove = endedDrag.event
                    
                    if displaySettings.constrainEventsToBounds {
                        let timelineBounds = metrics.timeline.dateRange
                        let maxStartDate = timelineBounds.upperBound.addingTimeInterval(-endedDrag.originalDuration)
                        eventToMove.startDate = min(max(newStartDate, timelineBounds.lowerBound), max(timelineBounds.lowerBound, maxStartDate))
                    } else {
                        eventToMove.startDate = newStartDate
                    }
                    
                    if eventToMove.isDuration {
                        eventToMove.endDate = eventToMove.startDate.addingTimeInterval(endedDrag.originalDuration)
                    }
                    
                    self.ghostEvent = nil
                    self.dragOffset = .zero
                    
                    recalculateLayouts()
                    
                    onEventMoved(eventToMove, endedDrag.originalStartDate)
                }
            )
    }

    private func calculateMinZoom() -> CGFloat {
        let axisLength = orientation == .vertical ? visibleSize.height : visibleSize.width
        return metrics.calculateMinZoom(for: axisLength)
    }
    
    private func recalculateLayouts() {
        guard ghostEvent == nil else { return }
        let crossAxisSize = orientation == .vertical ? visibleSize.width - axisSize : visibleSize.height - axisSize
        self.layouts = generateLayouts(containerCrossAxisSize: crossAxisSize)
    }

    private func generateLayouts(containerCrossAxisSize: CGFloat) -> [LayoutEvent] {
        var newLayouts: [LayoutEvent] = []
        let arcEvents = events.filter { $0.isArcEvent }
        let regularEvents = events.filter { !$0.isArcEvent }

        let hasArcLane = !arcEvents.isEmpty
        let arcLaneSize: CGFloat = 10.0
        let touchExpansion: CGFloat = 12.0
        for event in arcEvents {
            let startPos = metrics.position(for: event.startDate, at: zoomScale)
            let length = metrics.pureLength(for: event.effectiveDuration, at: zoomScale)
            let frame: CGRect = orientation == .vertical ?
                CGRect(x: axisSize - touchExpansion, y: startPos, width: arcLaneSize + touchExpansion, height: max(1, length)) :
                CGRect(x: startPos, y: axisSize - touchExpansion, width: max(1, length), height: arcLaneSize + touchExpansion)
            newLayouts.append(LayoutEvent(event: event, frame: frame))
        }

        let regularContainerSize = containerCrossAxisSize - (hasArcLane ? arcLaneSize : 0)
        let regularContainerOffset = axisSize + (hasArcLane ? arcLaneSize : 0)
        guard !regularEvents.isEmpty, regularContainerSize > 0 else { return newLayouts }
        
        let pps = metrics.pointsPerSecond(at: zoomScale)
        guard pps > 0 else { return newLayouts }

        let minPoints = orientation == .horizontal ? 180.0 : 44.0
        let minDuration = minPoints / pps

        let sortedEvents = regularEvents.sorted { $0.startDate < $1.startDate }

        // --- Group overlapping events ---
        var collisionGroups: [[Event]] = []
        if let firstEvent = sortedEvents.first {
            var currentGroup = [firstEvent]
            var groupVisualEnd = firstEvent.startDate.addingTimeInterval(max(firstEvent.effectiveDuration, minDuration))
            
            for i in 1..<sortedEvents.count {
                let event = sortedEvents[i]
                let eventVisualStart = event.startDate
                
                if eventVisualStart < groupVisualEnd {
                    currentGroup.append(event)
                    let eventVisualEnd = event.startDate.addingTimeInterval(max(event.effectiveDuration, minDuration))
                    groupVisualEnd = max(groupVisualEnd, eventVisualEnd)
                } else {
                    collisionGroups.append(currentGroup)
                    currentGroup = [event]
                    groupVisualEnd = event.startDate.addingTimeInterval(max(event.effectiveDuration, minDuration))
                }
            }
            collisionGroups.append(currentGroup)
        }

        // --- Process each group independently ---
        for group in collisionGroups {
            var lanes: [Date] = []
            var eventLanes: [ObjectIdentifier: Int] = [:]

            for event in group {
                let visualEndTime = event.startDate.addingTimeInterval(max(event.effectiveDuration, minDuration))
                var placed = false
                for i in 0..<lanes.count {
                    if event.startDate >= lanes[i] {
                        eventLanes[event.id] = i
                        lanes[i] = visualEndTime
                        placed = true
                        break
                    }
                }
                if !placed {
                    let newLaneIndex = lanes.count
                    eventLanes[event.id] = newLaneIndex
                    lanes.append(visualEndTime)
                }
            }
            
            let totalLanesInGroup = lanes.count
            let laneSize = totalLanesInGroup > 0 ? max(44, regularContainerSize / CGFloat(totalLanesInGroup)) : regularContainerSize

            for event in group {
                guard let laneIndex = eventLanes[event.id] else { continue }
                
                let startPos = metrics.position(for: event.startDate, at: zoomScale)
                let mainAxisLength = max(metrics.pureLength(for: event.effectiveDuration, at: zoomScale), minPoints)
                let crossAxisLaneOffset = CGFloat(laneIndex) * laneSize
                let crossAxisStart = regularContainerOffset + crossAxisLaneOffset
                
                let frame: CGRect = orientation == .vertical ?
                    CGRect(x: crossAxisStart, y: startPos, width: laneSize, height: mainAxisLength) :
                    CGRect(x: startPos, y: crossAxisStart, width: mainAxisLength, height: laneSize)
                newLayouts.append(LayoutEvent(event: event, frame: frame))
            }
        }
        return newLayouts
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
            if self.scrollPosition != value {
                self.scrollPosition = value
            }
        }
    }
}
struct LayoutEvent: Identifiable {
    let event: Event
    var frame: CGRect
    var id: ObjectIdentifier { event.id }
}
struct TimelineMetrics {
    let timeline: Timeline
    var bounds: ClosedRange<Date> { timeline.dateRange }
    
    func pointsPerSecond(at zoomScale: CGFloat) -> CGFloat { (120.0 * zoomScale) / 3600 }
    func position(for date: Date, at zoomScale: CGFloat) -> CGFloat { date.timeIntervalSince(bounds.lowerBound) * pointsPerSecond(at: zoomScale) }
    func pureLength(for duration: TimeInterval, at zoomScale: CGFloat) -> CGFloat { duration * pointsPerSecond(at: zoomScale) }
    func date(at position: CGFloat, for zoomScale: CGFloat) -> Date { bounds.lowerBound.addingTimeInterval(position / pointsPerSecond(at: zoomScale)) }
    func dateInterval(for position: CGFloat, length: CGFloat, at zoomScale: CGFloat) -> DateInterval { DateInterval(start: date(at: position, for: zoomScale), end: date(at: position + length, for: zoomScale)) }
    
    func calculateMinZoom(for axisLength: CGFloat) -> CGFloat {
        let totalDuration = timeline.dateRange.upperBound.timeIntervalSince(timeline.dateRange.lowerBound)
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
        let yearSeconds = 31556952.0 // Average, for threshold checks
        let pps = metrics.pointsPerSecond(at: zoomScale)
        
        let scale: (unit: Calendar.Component, step: Int, minorFormat: Date.FormatStyle, majorFormat: Date.FormatStyle, majorUnit: Calendar.Component)
        
        if pps * 3600 > minMarkerSpacing {
            scale = (.hour, 1, .dateTime.hour(), .dateTime.hour().day().month(.abbreviated), .day)
        } else if pps * 86400 > minMarkerSpacing {
            scale = (.day, 1, .dateTime.day(), .dateTime.month(.abbreviated).day(), .month)
        } else if pps * 86400 * 7 > minMarkerSpacing {
            scale = (.day, 7, .dateTime.day(), .dateTime.month(.abbreviated).day(), .month)
        } else if pps * yearSeconds / 12 > minMarkerSpacing {
            scale = (.month, 1, .dateTime.month(.abbreviated), .dateTime.year().month(.abbreviated), .year)
        } else if pps * yearSeconds > minMarkerSpacing {
            scale = (.year, 1, .dateTime.year(), .dateTime.year(), .year)
        } else if pps * yearSeconds * 5 > minMarkerSpacing {
            scale = (.year, 5, .dateTime.year(), .dateTime.year(), .year)
        } else if pps * yearSeconds * 10 > minMarkerSpacing {
            scale = (.year, 10, .dateTime.year(), .dateTime.year(), .year)
        } else if pps * yearSeconds * 50 > minMarkerSpacing {
            scale = (.year, 50, .dateTime.year(), .dateTime.year(), .year)
        } else if pps * yearSeconds * 100 > minMarkerSpacing {
            scale = (.year, 100, .dateTime.year(), .dateTime.year(), .year)
        } else {
            scale = (.year, 1000, .dateTime.year(), .dateTime.year(), .year)
        }
        
        var currentDate: Date
        if scale.unit == .year && scale.step > 1 {
            let startYear = calendar.component(.year, from: visibleInterval.start)
            let roundedStartYear = (startYear / scale.step) * scale.step
            var components = DateComponents(); components.year = roundedStartYear; components.month = 1; components.day = 1
            currentDate = calendar.date(from: components) ?? visibleInterval.start
        } else {
            guard var date = calendar.dateInterval(of: scale.unit, for: visibleInterval.start)?.start else { return [] }
            if scale.unit == .day, scale.step == 7 { date = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date }
            currentDate = date
        }

        while currentDate <= visibleInterval.end {
            let isMajor: Bool
            if scale.unit == .year && scale.step > 1 {
                let year = calendar.component(.year, from: currentDate)
                isMajor = year % (scale.step * 10) == 0
            } else {
                let majorUnitValue = calendar.component(scale.majorUnit, from: currentDate)
                let prevDate = calendar.date(byAdding: .second, value: -1, to: currentDate)!
                let prevMajorUnitValue = calendar.component(scale.majorUnit, from: prevDate)
                isMajor = majorUnitValue != prevMajorUnitValue
            }

            let label = currentDate.formatted(isMajor ? scale.majorFormat : scale.minorFormat)
            markers.append((currentDate, label, isMajor))
            
            guard let nextDate = calendar.date(byAdding: scale.unit, value: scale.step, to: currentDate), nextDate > currentDate else { break }
            currentDate = nextDate
        }
        return markers
    }
}
struct EventView: View {
    let event: Event
    let orientation: TimelineOrientation
    let displaySettings: DisplaySettings
    
    private static let dateFormat = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()
    
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
        let arcBarSize: CGFloat = 10.0
        let alignment: Alignment = orientation == .vertical ? .trailing : .bottom

        return ZStack(alignment: alignment) {
            Color.clear.contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 4)
                .fill(event.color)
                .if(orientation == .vertical) { $0.frame(width: arcBarSize) }
                .if(orientation == .horizontal) { $0.frame(height: arcBarSize) }
        }
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
            if displaySettings.showDuration, let durationText = formattedDuration() {
                Label(durationText, systemImage: "hourglass").font(.caption).foregroundColor(.secondary)
            }
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
            if displaySettings.showDuration, let durationText = formattedDuration() {
                Label(durationText, systemImage: "hourglass").font(.caption).foregroundColor(.secondary)
            }
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
        let startString = if event.precision == .time {
            event.startDate.formatted(Self.dateFormat) + ", " + event.startDate.formatted(Self.timeFormat)
        } else {
            event.startDate.formatted(Self.dateFormat)
        }
        
        guard let endDate = event.endDate else { return startString }

        let endString = if event.precision == .time {
            if Calendar.current.isDate(event.startDate, inSameDayAs: endDate) {
                endDate.formatted(Self.timeFormat)
            } else {
                endDate.formatted(Self.dateFormat) + ", " + endDate.formatted(Self.timeFormat)
            }
        } else {
            endDate.formatted(Self.dateFormat)
        }
        
        return startString == endString ? startString : "\(startString) – \(endString)"
    }
    
    private func formattedDuration() -> String? {
        guard event.isDuration, event.duration > 0 else { return nil }
        
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.maximumUnitCount = 5
        
        return formatter.string(from: event.duration)
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
            .navigationTitle("Go to Date")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct DisplaySettingsView: View {
    @Binding var displaySettings: DisplaySettings
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Display & Interaction") {
                    Toggle("Enable Dragging", isOn: $displaySettings.isDragEnabled)
                    Toggle("Tap Timeline to Add Event", isOn: $displaySettings.isTapToAddEnabled)
                    Toggle("Show Duration", isOn: $displaySettings.showDuration)
                }
                
                Section("Event Card Content") {
                    Toggle("Show Title", isOn: $displaySettings.showTitle)
                    Toggle("Show Details", isOn: $displaySettings.showDetails)
                    Toggle("Show People", isOn: $displaySettings.showPeople)
                    Toggle("Show Locations", isOn: $displaySettings.showLocations)
                }
                
                Section("Data Rules") {
                    Toggle("Constrain Events to Timeline Bounds", isOn: $displaySettings.constrainEventsToBounds)
                }
            }
            .navigationTitle("Display Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        displaySettings.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

fileprivate struct TimelineRow: View {
    let timeline: Timeline
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(timeline.name).font(.headline)
                Text("\(timeline.startDate.formatted()) – \(timeline.endDate.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }
}

struct TimelineSelectorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    // Get the PurchaseManager from the environment.
    @Environment(PurchaseManager.self) private var purchaseManager
    
    @Query(sort: \Timeline.name) private var timelines: [Timeline]
    @Binding var activeTimeline: Timeline?
    
    @State private var timelineToEdit: Timeline?
    @State private var showNewTimelineSheet = false
    // Add state to control the paywall's visibility.
    @State private var showPaywall = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(timelines) { timeline in
                    TimelineRow(timeline: timeline, isActive: timeline == activeTimeline)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            activeTimeline = timeline
                            dismiss()
                        }
                        .swipeActions {
                            Button("Edit", systemImage: "pencil") {
                                timelineToEdit = timeline
                            }
                            .tint(.orange)
                            
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                delete(timeline: timeline)
                            }
                        }
                }
            }
            .navigationTitle("Timelines")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New", systemImage: "plus") {
                        // This is the core paywall logic.
                        if timelines.count >= 1 && !purchaseManager.hasProAccess {
                            showPaywall = true
                        } else {
                            showNewTimelineSheet = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showNewTimelineSheet) {
                TimelineEditorView(onSave: { newTimeline in
                    activeTimeline = newTimeline
                    // After creating a new one, we might need to dismiss this view.
                    if !purchaseManager.hasProAccess {
                        dismiss()
                    }
                })
            }
            .sheet(item: $timelineToEdit) { timeline in
                TimelineEditorView(timelineToEdit: timeline)
            }
            // Add the sheet modifier for the PaywallView.
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .onChange(of: purchaseManager.hasProAccess) { _, hasAccess in
                // If the user successfully purchases, dismiss the paywall.
                if hasAccess {
                    showPaywall = false
                }
            }
        }
    }
    
    private func delete(timeline: Timeline) {
        if timeline == activeTimeline {
            activeTimeline = timelines.first(where: { $0.id != timeline.id })
        }
        modelContext.delete(timeline)
    }
}

struct TimelineEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    var timelineToEdit: Timeline?
    var onSave: ((Timeline) -> Void)?
    
    @State private var name: String = ""
    @State private var startDate: Date = Date.now
    @State private var endDate: Date = Date.now.addingTimeInterval(86400)
    
    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endDate > startDate
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Timeline Details") {
                    TextField("Name", text: $name)
                    DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle(timelineToEdit == nil ? "New Timeline" : "Edit Timeline")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear(perform: setup)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!isFormValid) }
            }
        }
    }
    
    private func setup() {
        if let timeline = timelineToEdit {
            name = timeline.name
            startDate = timeline.startDate
            endDate = timeline.endDate
        }
    }
    
    private func save() {
        if let timeline = timelineToEdit {
            timeline.name = name
            timeline.startDate = startDate
            timeline.endDate = endDate
        } else {
            let newTimeline = Timeline(name: name, startDate: startDate, endDate: endDate)
            modelContext.insert(newTimeline)
            onSave?(newTimeline)
        }
        dismiss()
    }
}

struct EventEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss
    
    @Query(sort: \Person.name) private var allPeople: [Person]
    @Query(sort: \Location.name) private var allLocations: [Location]
    
    var event: Event?
    let timeline: Timeline
    var initialDate: Date? = nil
    @Binding var displaySettings: DisplaySettings
    
    // MARK: State
    @State private var title: String = ""
    @State private var details: String = ""
    @State private var startDate: Date = Date.now
    @State private var endDate: Date? = nil
    @State private var hasEndDate: Bool = false
    @State private var precision: TimePrecision = .day
    @State private var isArcEvent: Bool = false
    @State private var colorHex: String?
    @State private var customColor: Color = .accentColor
    @State private var selectedPeople = Set<Person>()
    @State private var selectedLocations = Set<Location>()
    @State private var showDeleteConfirmation = false
    
    // Duration Input State
    @State private var endDateMode: EndDateMode = .date
    @State private var durationYears: Int = 0
    @State private var durationMonths: Int = 0
    @State private var durationDays: Int = 1
    @State private var durationHours: Int = 0
    @State private var durationMinutes: Int = 0
    
    // Tag-along State
    @State private var showAddPersonAlert = false
    @State private var newPersonName = ""
    @State private var showAddLocationAlert = false
    @State private var newLocationName = ""
    
    private enum EndDateMode: String, CaseIterable, Identifiable {
        case date = "By Date"
        case duration = "By Duration"
        var id: String { self.rawValue }
    }
    
    private let presetColors: [ColorChoice] = ColorChoice.presets
    private var unselectedPeople: [Person] { allPeople.filter { !selectedPeople.contains($0) } }
    private var unselectedLocations: [Location] { allLocations.filter { !selectedLocations.contains($0) } }

    private var startDatePickerRange: ClosedRange<Date> {
        displaySettings.constrainEventsToBounds ? timeline.dateRange : Date.distantPast...Date.distantFuture
    }
    
    private var endDatePickerRange: ClosedRange<Date> {
        displaySettings.constrainEventsToBounds ? startDate...timeline.endDate : startDate...Date.distantFuture
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) }
                
                Section("Look") {
                    Toggle("Arc Event", isOn: $isArcEvent.animation())
                    HStack {
                        ForEach(presetColors) { choice in
                            Circle().fill(choice.color).frame(width: 30, height: 30).overlay(Circle().stroke(Color.primary, lineWidth: colorHex == choice.id ? 2 : 0)).onTapGesture { colorHex = choice.id; customColor = choice.color }
                        }
                        ColorPicker("", selection: $customColor, supportsOpacity: false).labelsHidden()
                        Spacer()
                    }
                    if colorHex != nil { Button("Clear Color", role: .destructive) { colorHex = nil; customColor = .accentColor } }
                }
                
                Section("Date & Time") {
                    Picker("Precision", selection: $precision.animation()) {
                        ForEach(TimePrecision.allCases, id: \.self) { p in Text(p.description).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 4)

                    DatePicker("Start", selection: $startDate, in: startDatePickerRange, displayedComponents: precision == .time ? [.date, .hourAndMinute] : [.date])
                        .id("start-\(precision.rawValue)-\(displaySettings.constrainEventsToBounds)")

                    Toggle("End Date", isOn: $hasEndDate.animation())

                    if hasEndDate {
                        Picker("Input Method", selection: $endDateMode.animation()) {
                            ForEach(EndDateMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        
                        if endDateMode == .date {
                            DatePicker("End", selection: Binding( get: { endDate ?? startDate }, set: { endDate = $0 }), in: endDatePickerRange, displayedComponents: precision == .time ? [.date, .hourAndMinute] : [.date]
                            )
                            .id("end-\(precision.rawValue)-\(displaySettings.constrainEventsToBounds)")
                        } else {
                            compoundDurationEditor
                        }
                        durationInfoView
                    }
                }
                
                if !isArcEvent {
                    Group {
                        Section("People") {
                            ForEach(Array(selectedPeople).sorted(by: { $0.name < $1.name })) { person in HStack { Text(person.name); Spacer(); Button { selectedPeople.remove(person) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) } }.buttonStyle(.borderless) }
                            Menu("Add Person") {
                                if !unselectedPeople.isEmpty { ForEach(unselectedPeople) { p in Button(p.name) { selectedPeople.insert(p) } }; Divider() }
                                Button("Add New Person...") { showAddPersonAlert = true }
                            }
                        }
                        
                        Section("Locations") {
                            ForEach(Array(selectedLocations).sorted(by: { $0.name < $1.name })) { location in HStack { Text(location.name); Spacer(); Button { selectedLocations.remove(location) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) } }.buttonStyle(.borderless) }
                            Menu("Add Location") {
                                if !unselectedLocations.isEmpty { ForEach(unselectedLocations) { l in Button(l.name) { selectedLocations.insert(l) } }; Divider() }
                                Button("Add New Location...") { showAddLocationAlert = true }
                            }
                        }
                        Section("Description") { TextEditor(text: $details).frame(minHeight: 120) }
                    }
                }
                
                if event != nil { Section { Button("Delete Event", role: .destructive) { showDeleteConfirmation = true } } }
            }
            .navigationTitle(event == nil ? "New Event" : "Edit Event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(title.isEmpty) }
            }
            .onAppear(perform: setupInitialState)
            .onChange(of: customColor) { _, newColor in colorHex = newColor.toHex() }
            .onChange(of: hasEndDate) { _, newHasEndDate in if !newHasEndDate { endDate = nil } else if endDate == nil { updateEndDateFromDurationFields() } }
            .onChange(of: endDate) { updateDurationFieldsFromEndDate() }
            .onChange(of: endDateMode) { _, newMode in if newMode == .duration { updateDurationFieldsFromEndDate() } }
            .onChange(of: durationComponents) { updateEndDateFromDurationFields() }
            .onChange(of: precision) { _, newPrecision in if newPrecision == .day { durationHours = 0; durationMinutes = 0; updateEndDateFromDurationFields() } }
            .alert("Delete Event?", isPresented: $showDeleteConfirmation) { Button("Delete", role: .destructive, action: deleteEvent); Button("Cancel", role: .cancel) {} } message: { Text("This action cannot be undone.") }
            .alert("New Person", isPresented: $showAddPersonAlert) {
                TextField("Name", text: $newPersonName)
                Button("Add", action: createAndSelectPerson).disabled(newPersonName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("New Location", isPresented: $showAddLocationAlert) {
                TextField("Name", text: $newLocationName)
                Button("Add", action: createAndSelectLocation).disabled(newLocationName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    
    @ViewBuilder private var compoundDurationEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            durationInputRow(label: "Years", value: $durationYears)
            durationInputRow(label: "Months", value: $durationMonths)
            durationInputRow(label: "Days", value: $durationDays)
            if precision == .time {
                durationInputRow(label: "Hours", value: $durationHours)
                durationInputRow(label: "Minutes", value: $durationMinutes)
            }
        }
    }
    
    private func durationInputRow(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            TextField("", value: value, format: .number)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            Stepper(label, value: value, in: 0...999).labelsHidden()
        }
    }
    
    @ViewBuilder private var durationInfoView: some View {
        if let formatted = formattedDuration {
            Text("Duration: \(formatted)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
    
    private var durationComponents: [Int] { [durationYears, durationMonths, durationDays, durationHours, durationMinutes] }

    private var formattedDuration: String? {
        guard let endDate, hasEndDate, endDate > startDate else { return nil }
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: startDate, to: endDate)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.maximumUnitCount = 5
        
        return formatter.string(from: components)
    }

    private func setupInitialState() {
        if let event {
            title = event.title; details = event.details; startDate = event.startDate; endDate = event.endDate; precision = event.precision; colorHex = event.colorHex; isArcEvent = event.isArcEvent
            hasEndDate = event.endDate != nil
            selectedPeople = Set(event.people ?? []); selectedLocations = Set(event.locations ?? [])
            customColor = Color(hex: colorHex) ?? .accentColor
        } else {
            startDate = initialDate ?? Date.now
            if displaySettings.constrainEventsToBounds && !timeline.dateRange.contains(startDate) {
                startDate = timeline.startDate
            }
            hasEndDate = false
        }
        updateDurationFieldsFromEndDate()
    }
    
    private func save() {
        let calendar = Calendar.current
        let finalPrecision = precision
        let finalStartDate = finalPrecision == .day ? calendar.startOfDay(for: startDate) : startDate
        var finalEndDate: Date?
        if let currentEndDate = endDate, hasEndDate {
            finalEndDate = finalPrecision == .day ? calendar.startOfDay(for: currentEndDate) : currentEndDate
        }
        
        if !displaySettings.constrainEventsToBounds {
            let eventEffectiveEndDate = finalEndDate ?? finalStartDate
            var newTimelineStartDate = timeline.startDate
            var newTimelineEndDate = timeline.endDate

            let didExpandStart = finalStartDate < newTimelineStartDate
            let didExpandEnd = eventEffectiveEndDate > newTimelineEndDate

            if didExpandStart { newTimelineStartDate = finalStartDate }
            if didExpandEnd { newTimelineEndDate = eventEffectiveEndDate }

            if didExpandStart || didExpandEnd {
                let totalDuration = newTimelineEndDate.timeIntervalSince(newTimelineStartDate)
                let buffer = totalDuration > 0 ? totalDuration * 0.05 : 86400.0 // 5% or 1 day
                
                if didExpandStart {
                    newTimelineStartDate = newTimelineStartDate.addingTimeInterval(-buffer)
                }
                if didExpandEnd {
                    newTimelineEndDate = newTimelineEndDate.addingTimeInterval(buffer)
                }
                
                timeline.startDate = newTimelineStartDate
                timeline.endDate = newTimelineEndDate
            }
        }

        if let event {
            event.title = title; event.details = isArcEvent ? "" : details; event.startDate = finalStartDate; event.endDate = finalEndDate; event.precision = finalPrecision; event.colorHex = colorHex; event.isArcEvent = isArcEvent
            event.people = isArcEvent ? [] : Array(selectedPeople); event.locations = isArcEvent ? [] : Array(selectedLocations)
        } else {
            let newEvent = Event(startDate: finalStartDate, endDate: finalEndDate, title: title, details: isArcEvent ? "" : details, precision: finalPrecision, colorHex: colorHex, isArcEvent: isArcEvent)
            newEvent.timeline = timeline
            newEvent.people = isArcEvent ? [] : Array(selectedPeople); newEvent.locations = isArcEvent ? [] : Array(selectedLocations)
            modelContext.insert(newEvent)
        }
        dismiss()
    }
    
    private func deleteEvent() { if let event { modelContext.delete(event) }; dismiss() }
    
    private func createAndSelectPerson() {
        let name = newPersonName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        
        // Before creating, check if a person with this name already exists
        let existing = allPeople.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let personToSelect = existing ?? Person(name: name)
        
        if existing == nil {
            modelContext.insert(personToSelect)
        }
        selectedPeople.insert(personToSelect)
    }
    
    private func createAndSelectLocation() {
        let name = newLocationName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        
        // Before creating, check if a location with this name already exists
        let existing = allLocations.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let locationToSelect = existing ?? Location(name: name)
        
        if existing == nil {
            modelContext.insert(locationToSelect)
        }
        selectedLocations.insert(locationToSelect)
    }
    
    private func updateEndDateFromDurationFields() {
        guard hasEndDate else { return }
        let components = DateComponents(year: durationYears, month: durationMonths, day: durationDays, hour: durationHours, minute: durationMinutes)
        if var newEndDate = Calendar.current.date(byAdding: components, to: startDate) {
            if displaySettings.constrainEventsToBounds {
                newEndDate = min(newEndDate, timeline.endDate)
            }
            endDate = newEndDate
        }
    }
    
    private func updateDurationFieldsFromEndDate() {
        guard let endDate = self.endDate, endDate > startDate, hasEndDate else {
            durationYears = 0; durationMonths = 0; durationDays = 1; durationHours = 0; durationMinutes = 0
            return
        }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: startDate, to: endDate)
        durationYears = components.year ?? 0
        durationMonths = components.month ?? 0
        durationDays = components.day ?? 0
        durationHours = components.hour ?? 0
        durationMinutes = components.minute ?? 0
    }
}


// MARK: - Color Helpers

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

struct ColorChoice: Identifiable, Hashable {
    let id: String, color: Color
    static let presets: [ColorChoice] = [
        .init(id: "#5792F2", color: .blue),
        .init(id: "#4CAF50", color: .green),
        .init(id: "#FFC107", color: .yellow),
        .init(id: "#FF9800", color: .orange),
        .init(id: "#F44336", color: .red),
        .init(id: "#9C27B0", color: .purple)
    ]
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
        let pColor = PlatformColor(self)
        guard let components = pColor.cgColor.components, components.count >= 3 else { return nil }
        let r = Float(components[0]); let g = Float(components[1]); let b = Float(components[2])
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

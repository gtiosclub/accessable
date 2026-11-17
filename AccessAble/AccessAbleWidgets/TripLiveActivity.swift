import ActivityKit
import SwiftUI
import WidgetKit

/// Owner: Maps + Location (2.x). The trip on the lock screen and in the Dynamic Island, drawn
/// large and white on black so it can be read at a glance with low vision.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLockScreenView(state: context.state, destinationName: context.attributes.destinationName)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let sentence = context.state.accessibilityLabel(destinationName: context.attributes.destinationName)
            return DynamicIsland {
                // the bottom region's sentence says what the symbol and distance show
                DynamicIslandExpandedRegion(.leading) {
                    TurnSymbol(state: context.state)
                        .font(.largeTitle.bold())
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let distance = context.state.distance {
                        Text(distance)
                            .font(.title2.bold())
                            .accessibilityHidden(true)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.headline(destinationName: context.attributes.destinationName))
                        .font(.title3.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel(sentence)
                }
            } compactLeading: {
                // the pair reads as one element: the sentence here, the trailing text hidden
                TurnSymbol(state: context.state)
                    .accessibilityLabel(sentence)
            } compactTrailing: {
                if let text = context.state.shortText {
                    Text(text)
                        .bold()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityHidden(true)
                }
            } minimal: {
                TurnSymbol(state: context.state)
                    .accessibilityLabel(sentence)
            }
        }
    }
}

/// Takes the state rather than the activity's context, so previews can show it at any text size.
private struct TripLockScreenView: View {
    let state: TripActivityAttributes.ContentState
    let destinationName: String
    /// Grows with the text, so the turn stays as easy to see as the words beside it.
    @ScaledMetric(relativeTo: .title) private var symbolSize = 48
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // at accessibility sizes the symbol gives way to the words, which say the same
            if !dynamicTypeSize.isAccessibilitySize {
                TurnSymbol(state: state)
                    .font(.system(size: symbolSize, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(state.headline(destinationName: destinationName))
                    .font(.title.bold())
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                if state.status == .active {
                    // within the lock screen's height the distance is sized first and the instruction
                    // shrinks to fit; the arrival time is the first thing dropped
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            distanceText
                            if let arrival = state.arrival {
                                Text("Arrive \(Text(arrival, style: .time))")
                            }
                        }
                        distanceText
                    }
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel(destinationName: destinationName))
    }

    @ViewBuilder private var distanceText: some View {
        if let distance = state.distance {
            Text(distance)
        }
    }
}

private struct TurnSymbol: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.status == .offRoute ? .yellow : .white)
    }
}

private extension TripActivityAttributes.ContentState {
    func headline(destinationName: String) -> String {
        switch status {
        case .active, .offRoute: instruction
        case .paused: "Paused"
        case .arrived: "Arrived at \(destinationName)"
        }
    }

    var symbol: String {
        switch status {
        case .active: symbolName
        case .paused: "pause.fill"
        case .offRoute: "exclamationmark.triangle.fill"
        case .arrived: "mappin.and.ellipse"
        }
    }

    /// Fits beside the camera in the compact Dynamic Island.
    var shortText: String? {
        switch status {
        case .active: distance
        case .paused: "Paused"
        case .offRoute: "Off route"
        case .arrived: "Arrived"
        }
    }
}

#if DEBUG
extension TripActivityAttributes {
    static let preview = TripActivityAttributes(destinationName: "Clough Commons")
}

extension TripActivityAttributes.ContentState {
    static let active = Self(
        status: .active,
        instruction: "Turn left onto Ferst Drive",
        distance: "150 ft",
        spokenDistance: "150 feet",
        symbolName: "arrow.turn.up.left",
        arrival: .now.addingTimeInterval(8 * 60)
    )
    static let paused = Self(
        status: .paused,
        instruction: "Turn left onto Ferst Drive",
        distance: "150 ft",
        spokenDistance: "150 feet",
        symbolName: "arrow.turn.up.left",
        arrival: nil
    )
    static let offRoute = Self(
        status: .offRoute,
        instruction: "Off route. Finding a new way",
        distance: nil,
        spokenDistance: nil,
        symbolName: "arrow.turn.up.left",
        arrival: nil
    )
    static let arrived = Self(
        status: .arrived,
        instruction: "You have arrived",
        distance: nil,
        spokenDistance: nil,
        symbolName: "mappin.and.ellipse",
        arrival: nil
    )
}

#Preview("Lock screen", as: .content, using: TripActivityAttributes.preview) {
    TripLiveActivity()
} contentStates: {
    TripActivityAttributes.ContentState.active
    TripActivityAttributes.ContentState.paused
    TripActivityAttributes.ContentState.offRoute
    TripActivityAttributes.ContentState.arrived
}

#Preview("Dynamic Island expanded", as: .dynamicIsland(.expanded), using: TripActivityAttributes.preview) {
    TripLiveActivity()
} contentStates: {
    TripActivityAttributes.ContentState.active
    TripActivityAttributes.ContentState.paused
    TripActivityAttributes.ContentState.offRoute
    TripActivityAttributes.ContentState.arrived
}

#Preview("Dynamic Island compact", as: .dynamicIsland(.compact), using: TripActivityAttributes.preview) {
    TripLiveActivity()
} contentStates: {
    TripActivityAttributes.ContentState.active
    TripActivityAttributes.ContentState.paused
    TripActivityAttributes.ContentState.offRoute
    TripActivityAttributes.ContentState.arrived
}

#Preview("Lock screen, largest text") {
    let states: [TripActivityAttributes.ContentState] = [.active, .paused, .offRoute, .arrived]
    ScrollView {
        VStack(spacing: 8) {
            ForEach(states, id: \.self) { state in
                // the lock screen cuts a Live Activity off at 160 points
                TripLockScreenView(state: state, destinationName: TripActivityAttributes.preview.destinationName)
                    .frame(width: 360)
                    .frame(maxHeight: 160, alignment: .top)
                    .clipped()
                    .background(.black, in: .rect(cornerRadius: 20))
            }
        }
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif

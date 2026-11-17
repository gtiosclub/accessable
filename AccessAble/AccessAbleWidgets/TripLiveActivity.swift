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
            DynamicIsland {
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
                        .accessibilityLabel(
                            context.state.accessibilityLabel(destinationName: context.attributes.destinationName)
                        )
                }
            } compactLeading: {
                TurnSymbol(state: context.state)
            } compactTrailing: {
                if let text = context.state.shortText {
                    Text(text)
                        .bold()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            } minimal: {
                TurnSymbol(state: context.state)
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

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            TurnSymbol(state: state)
                .font(.system(size: symbolSize, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                Text(state.headline(destinationName: destinationName))
                    .font(.title.bold())
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                if state.status == .active {
                    HStack(spacing: 16) {
                        if let distance = state.distance {
                            Text(distance)
                        }
                        if let arrival = state.arrival {
                            Text("Arrive \(Text(arrival, style: .time))")
                        }
                    }
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel(destinationName: destinationName))
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
        symbolName: "arrow.turn.up.left",
        arrival: .now.addingTimeInterval(8 * 60)
    )
    static let paused = Self(
        status: .paused,
        instruction: "Turn left onto Ferst Drive",
        distance: "150 ft",
        symbolName: "arrow.turn.up.left",
        arrival: nil
    )
    static let offRoute = Self(
        status: .offRoute,
        instruction: "Off route. Finding a new way",
        distance: nil,
        symbolName: "arrow.turn.up.left",
        arrival: nil
    )
    static let arrived = Self(
        status: .arrived,
        instruction: "You have arrived",
        distance: nil,
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
#endif

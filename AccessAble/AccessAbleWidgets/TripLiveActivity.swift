import ActivityKit
import SwiftUI
import WidgetKit

/// Owner: Maps + Location (2.x). The trip on the lock screen and in the Dynamic Island, drawn
/// large and white on black so it can be read at a glance with low vision.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurnSymbol(state: context.state)
                        .font(.largeTitle.bold())
                        .accessibilityHidden(context.state.symbolIsDecorative)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let distance = context.state.distance {
                        Text(distance)
                            .font(.title2.bold())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.headline)
                        .font(.title3.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            } compactLeading: {
                TurnSymbol(state: context.state)
            } compactTrailing: {
                if let text = context.state.shortText {
                    Text(text)
                        .bold()
                }
            } minimal: {
                TurnSymbol(state: context.state)
            }
        }
    }
}

private struct TripLockScreenView: View {
    let context: ActivityViewContext<TripActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            TurnSymbol(state: context.state)
                .font(.system(size: 48, weight: .bold))
                .accessibilityHidden(context.state.symbolIsDecorative)
            VStack(alignment: .leading, spacing: 8) {
                Text(context.headline)
                    .font(.title.bold())
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                if context.state.status == .active {
                    HStack(spacing: 16) {
                        if let distance = context.state.distance {
                            Text(distance)
                        }
                        if let arrival = context.state.arrival {
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
    }
}

private struct TurnSymbol: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.status == .offRoute ? .yellow : .white)
    }
}

private extension ActivityViewContext<TripActivityAttributes> {
    var headline: String {
        switch state.status {
        case .active, .offRoute: state.instruction
        case .paused: "Paused"
        case .arrived: "Arrived at \(attributes.destinationName)"
        }
    }
}

private extension TripActivityAttributes.ContentState {
    var symbol: String {
        switch status {
        case .active: symbolName
        case .paused: "pause.fill"
        case .offRoute: "exclamationmark.triangle.fill"
        case .arrived: "mappin.and.ellipse"
        }
    }

    /// The headline says the same thing, except off route, where the warning sign is the cue.
    var symbolIsDecorative: Bool { status != .offRoute }

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

import SwiftUI
import SimAgentationPlus

struct Show: Identifiable {
    let id = UUID()
    let title: String
    let venue: String
    let time: String
    let doors: String
    let symbol: String
    let tint: Color
}

private let tonight: [Show] = [
    Show(title: "Phoebe Bridgers", venue: "Sydney Opera House", time: "8:00 PM", doors: "Doors 7:00", symbol: "music.mic", tint: .purple),
    Show(title: "Dune: Part Three", venue: "IMAX Darling Harbour", time: "9:15 PM", doors: "Seat F12", symbol: "film", tint: .orange),
    Show(title: "Hamilton", venue: "Lyric Theatre", time: "7:30 PM", doors: "Doors 6:45", symbol: "theatermasks", tint: .red),
]

public struct ContentView: View {
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NextUpCard(show: tonight[0])
                        .simTag()

                    Text("Later tonight")
                        .font(.headline)
                        .padding(.top, 8)

                    ForEach(tonight.dropFirst()) { show in
                        ShowRow(show: show)
                            .simTag()
                    }

                    VenueTips()
                        .simTag()
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("Tonight")
        }
        .simAgentation()
    }

    public init() {}
}

struct NextUpCard: View {
    let show: Show

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Next up", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(show.title)
                .font(.title2.bold())
            Text("\(show.venue) · \(show.time)")
                .foregroundStyle(.secondary)
            HStack {
                Text(show.doors)
                    .font(.footnote)
                Spacer()
                NavigationLink("Show ticket") {
                    TicketScreen(show: show)
                        .navigationTitle("Ticket")
                        .ignoresSafeArea(edges: .bottom)
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("showTicketButton")
            }
        }
        .padding(16)
        .background(show.tint.opacity(0.15), in: .rect(cornerRadius: 20))
    }
}

struct ShowRow: View {
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: show.symbol)
                .foregroundStyle(show.tint)
                .frame(width: 36, height: 36)
                .background(show.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.body.weight(.medium))
                Text(show.venue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(show.time)
                .font(.subheadline.monospacedDigit())
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

struct VenueTips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before you go")
                .font(.subheadline.weight(.semibold))
            Label("Bags larger than A4 aren't allowed", systemImage: "bag")
            Label("Arrive 30 min early for security", systemImage: "clock.badge.checkmark")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // Barely off-white: hard to find from pixels alone.
        .background(Color(white: 0.985), in: .rect(cornerRadius: 14))
        .padding(.top, 8)
    }
}

#Preview {
    ContentView()
}

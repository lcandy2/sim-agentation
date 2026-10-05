import SwiftUI
import UIKit
import SimAgentationPlus

/// A UIKit screen, to exercise SimAgentationPlus on UIKit views.
final class TicketViewController: UIViewController {
    private let show: Show

    init(show: Show) {
        self.show = show
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let card = TicketCardView(show: show).simTag()

        // SwiftUI inside UIKit, which in turn hosts a UIKit view.
        let pass = UIHostingController(rootView: EntryPassView(gate: "Gate 3").simTag())
        pass.sizingOptions = .intrinsicContentSize
        pass.view.backgroundColor = .clear
        addChild(pass)

        let wallet = UIButton(configuration: .filled())
        wallet.configuration?.title = "Add to Apple Wallet"
        wallet.configuration?.cornerStyle = .large

        let stack = UIStackView(arrangedSubviews: [card, pass.view, wallet])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        pass.didMove(toParent: self)
    }
}

/// SwiftUI view hosted by `TicketViewController`.
struct EntryPassView: View {
    let gate: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "qrcode")
                .font(.system(size: 56))
                .accessibilityLabel("Entry code")
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan at entry")
                    .font(.headline)
                GateBadge(gate: gate)
                    .fixedSize()
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }
}

/// UIKit view inside `EntryPassView`, via UIViewRepresentable.
struct GateBadge: UIViewRepresentable {
    let gate: String

    func makeUIView(context: Context) -> GateBadgeView { GateBadgeView(gate: gate) }
    func updateUIView(_ view: GateBadgeView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GateBadgeView, context: Context) -> CGSize? {
        uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }
}

final class GateBadgeView: UIView {
    init(gate: String) {
        super.init(frame: .zero)
        backgroundColor = .systemOrange.withAlphaComponent(0.18)
        let label = UILabel()
        label.text = gate
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// Rounded card with a background: easy to find from pixels too.
final class TicketCardView: UIView {
    init(show: Show) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = show.title
        title.font = .preferredFont(forTextStyle: .title2).bold()
        let venue = UILabel()
        venue.text = "\(show.venue) · \(show.time)"
        venue.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [title, venue, SeatInfoView()])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(20, after: venue)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Transparent container, not tagged: only its class name identifies it.
final class SeatInfoView: UIView {
    init() {
        super.init(frame: .zero)
        let columns = [("Section", "Stalls"), ("Row", "F"), ("Seat", "12")].map { label, value in
            let caption = UILabel()
            caption.text = label.uppercased()
            caption.font = .preferredFont(forTextStyle: .caption2)
            caption.textColor = .secondaryLabel
            let text = UILabel()
            text.text = value
            text.font = .preferredFont(forTextStyle: .headline)
            let column = UIStackView(arrangedSubviews: [caption, text])
            column.axis = .vertical
            column.spacing = 2
            return column
        }
        let row = UIStackView(arrangedSubviews: columns)
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private extension UIFont {
    func bold() -> UIFont {
        UIFont(descriptor: fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor, size: 0)
    }
}

struct TicketScreen: UIViewControllerRepresentable {
    let show: Show

    func makeUIViewController(context: Context) -> TicketViewController {
        TicketViewController(show: show)
    }

    func updateUIViewController(_ controller: TicketViewController, context: Context) {}
}

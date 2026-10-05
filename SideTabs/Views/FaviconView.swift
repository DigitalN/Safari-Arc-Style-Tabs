import SwiftUI

struct FaviconView: View {
    let iconURL: String?
    let pageURL: String?
    var size: CGFloat = 16

    @Environment(FaviconStore.self) private var favicons

    private var candidates: [String] {
        FaviconStore.candidates(iconURL: iconURL, pageURL: pageURL)
    }

    var body: some View {
        Group {
            if let image = favicons.image(for: candidates) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let host = pageURL.flatMap({ URL(string: $0)?.host() }), !host.isEmpty {
                LetterTile(host: host)
            } else {
                Image(systemName: "safari")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: candidates) {
            await favicons.load(candidates)
        }
    }
}

/// Stand-in for sites whose favicon can't be fetched.
struct LetterTile: View {
    let host: String

    private var letter: String {
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    private var color: Color {
        let hash = host.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.7)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .overlay {
                Text(letter)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

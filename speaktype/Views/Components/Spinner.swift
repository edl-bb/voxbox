import SwiftUI

/// A lightweight indeterminate spinner: a trimmed ring with a comet-tail fade
/// that rotates continuously. Cleaner and more modern than the native macOS
/// spinning-lines `ProgressView`, and it inherits the surrounding tint.
struct Spinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    var tint: Color = .textSecondary

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.82)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [tint.opacity(0), tint]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

#Preview {
    HStack(spacing: 16) {
        Spinner()
        Spinner(size: 20, lineWidth: 2.5, tint: .accentPrimary)
    }
    .padding(40)
}

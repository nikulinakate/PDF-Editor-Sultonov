import SwiftUI

struct SignatureSheet: View {
    let onSave: ([[CGPoint]], CGSize) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var canvasSize = CGSize(width: 1, height: 1)
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("signature.hint")).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    Canvas { context, size in
                        for stroke in strokes + [current] {
                            guard let first = stroke.first else { continue }
                            var path = Path(); path.move(to: first)
                            for point in stroke.dropFirst() { path.addLine(to: point) }
                            context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }.background(.white).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let point = CGPoint(x: max(0, min(value.location.x, geometry.size.width)), y: max(0, min(value.location.y, geometry.size.height)))
                            current.append(point)
                        }.onEnded { _ in if current.count > 1 { strokes.append(current) }; current = [] })
                        .onAppear { canvasSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in
                            // Normalize existing ink if the sheet rotates or changes size.
                            if canvasSize.width > 0, canvasSize.height > 0 {
                                strokes = strokes.map { $0.map { CGPoint(x: $0.x / canvasSize.width * size.width, y: $0.y / canvasSize.height * size.height) } }
                            }
                            canvasSize = size
                        }
                }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 16))
                Button(L("signature.clear"), systemImage: "eraser") { strokes = []; current = [] }
                Text(L("signature.typeHint")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(24).background(Theme.canvas)
                .navigationTitle(L("signature.title"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("signature.insert")) { onSave(strokes, canvasSize); dismiss() }.disabled(strokes.isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}

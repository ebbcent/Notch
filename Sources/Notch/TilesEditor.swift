import SwiftUI

/// Embedded in the menu: show/hide each tile and change their order.
struct TilesEditor: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(settings.tileOrder.enumerated()), id: \.element) { index, tile in
                HStack(spacing: 6) {
                    Toggle(tile.title, isOn: Binding(
                        get: { settings.isVisible(tile) },
                        set: { visible in
                            if visible { settings.hiddenTiles.remove(tile) } else { settings.hiddenTiles.insert(tile) }
                        }))
                        .toggleStyle(.checkbox)
                    Spacer(minLength: 8)
                    arrow("chevron.up", help: "Move \(tile.title) left", disabled: index == 0) {
                        move(index, by: -1)
                    }
                    arrow("chevron.down", help: "Move \(tile.title) right",
                          disabled: index == settings.tileOrder.count - 1) {
                        move(index, by: 1)
                    }
                }
                .frame(height: 22)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(width: 240, alignment: .leading)
    }

    private func arrow(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard settings.tileOrder.indices.contains(target) else { return }
        settings.tileOrder.swapAt(index, target)
    }
}

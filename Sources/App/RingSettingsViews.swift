import SwiftUI

/// Settings › General: which keys open which ring, and how many places a ring has. A key used by one ring is not offered for the others.
struct RingKeysSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section {
            ForEach(RingKind.allCases) { ring in
                Picker(selection: binding(for: ring)) {
                    ForEach(settings.ringKeys.choices(for: ring), id: \.rawValue) { combo in
                        Text("\(combo.symbols)  \(combo.names)").tag(combo)
                    }
                } label: {
                    Label(ring.title, systemImage: ring.symbol)
                }
            }
            Picker(tr("Places in a ring", "Plätze im Ring"), selection: $settings.ringItemCount) {
                ForEach(RingBuilder.countChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(tr("Rings", "Ringe"))
        } footer: {
            Text(tr("Hold the keys while dragging files in Finder. Hold Option as well when you let go to run a tool with its last settings, without its window. The last place of a ring is \u{201C}More …\u{201D} when there is more.",
                    "Tasten beim Ziehen von Dateien im Finder halten. Wer beim Loslassen zusätzlich Wahl (⌥) hält, startet ein Werkzeug mit den letzten Einstellungen, ohne Fenster. Der letzte Platz eines Rings ist \u{201E}Mehr …\u{201C}, wenn es mehr gibt."))
        }
    }

    private func binding(for ring: RingKind) -> Binding<ModifierCombo> {
        Binding(get: { settings.ringKeys.combo(for: ring) }, set: { combo in
            var keys = settings.ringKeys
            keys.set(combo, for: ring)
            settings.ringKeys = keys
        })
    }
}

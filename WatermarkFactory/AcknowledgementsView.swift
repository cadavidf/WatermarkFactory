import AutomalityUI
import SwiftUI

/// Third-party license text shown in the Acknowledgements window. Kept as
/// plain data here (not fetched at runtime) so the app works offline and the
/// text can't silently drift from what's actually bundled -- when a
/// dependency changes, this needs a matching manual update (see
/// LICENSES_TODO.md for the process).
struct AcknowledgementEntry: Identifiable {
    let id = UUID()
    let name: String
    let licenseSummary: String
    let fullText: String
}

enum Acknowledgements {
    static let entries: [AcknowledgementEntry] = [
        AcknowledgementEntry(
            name: "Sparkle",
            licenseSummary: "MIT-style license. Copyright (c) 2006-2013 Andy Matuschak and others.",
            fullText: """
            Copyright (c) 2006-2013 Andy Matuschak.
            Copyright (c) 2009-2013 Elgato Systems GmbH.
            Copyright (c) 2011-2014 Kornel Lesiński.
            Copyright (c) 2015-2017 Mayur Pawashe.
            Copyright (c) 2014 C.W. Betts.
            Copyright (c) 2014 Petroules Corporation.
            Copyright (c) 2014 Big Nerd Ranch.
            All rights reserved.

            Permission is hereby granted, free of charge, to any person obtaining a copy of \
            this software and associated documentation files (the "Software"), to deal in \
            the Software without restriction, including without limitation the rights to \
            use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of \
            the Software, and to permit persons to whom the Software is furnished to do so, \
            subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all \
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS \
            FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR \
            COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
            IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN \
            CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

            --- Embedded third-party code within Sparkle ---

            bspatch.c / bsdiff.c (bsdiff 4.3): Copyright 2003-2005 Colin Percival. \
            BSD-style, redistribution permitted with attribution retained.

            sais.c / sais.h (sais-lite): Copyright (c) 2008-2010 Yuta Mori. MIT-style.

            Portable C Ed25519 implementation: Copyright (c) 2015 Orson Peters. \
            zlib-style license.

            SUSignatureVerifier.m: Copyright (c) 2011 Mark Hamlin. BSD-style.

            Full text: https://github.com/sparkle-project/Sparkle/blob/main/LICENSE
            """
        )
    ]
}

struct AcknowledgementsView: View {
    @State private var expandedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AutomalitySpacing.md) {
                Text("Acknowledgements")
                    .font(AutomalityType.display(28))
                    .foregroundStyle(AutomalityColor.tealDeep)

                Text("WatermarkFactory is built on the open-source software listed below. Each entry's full license text is included, as required by its terms.")
                    .font(AutomalityType.body())
                    .foregroundStyle(AutomalityColor.inkMuted)

                ForEach(Acknowledgements.entries) { entry in
                    AutomalitySectionBox(entry.name) {
                        VStack(alignment: .leading, spacing: AutomalitySpacing.sm) {
                            Text(entry.licenseSummary)
                                .font(AutomalityType.body())
                                .foregroundStyle(AutomalityColor.ink)
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedID == entry.id },
                                    set: { expandedID = $0 ? entry.id : nil }
                                )
                            ) {
                                Text(entry.fullText)
                                    .font(AutomalityType.data(11))
                                    .foregroundStyle(AutomalityColor.inkMuted)
                                    .textSelection(.enabled)
                                    .padding(.top, AutomalitySpacing.xs)
                            } label: {
                                Text("Full license text")
                                    .font(AutomalityType.label(11))
                            }
                        }
                    }
                }

                Text("This app's own code, icon, and the Automality design system (AutomalityUI, DesignSystemKit) are original work, not third-party.")
                    .font(.caption)
                    .foregroundStyle(AutomalityColor.inkMuted)
            }
            .padding(AutomalitySpacing.lg)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 560)
        .background(AutomalityColor.gray100)
    }
}

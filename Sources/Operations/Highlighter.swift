import CoreGraphics

/// Highlighter on photographed or scanned pages. On strong pink or green Apple's text recognition loses a line or reads
/// it as nonsense (measured with own test pages; light yellow it reads well). The colour is taken out before
/// reading: inside highlighted bands every pixel becomes its brightest channel, so the coloured paper turns nearly white
/// and the dark letters stay dark. Only bands are changed (wide, mostly filled with a light, clear colour), so coloured
/// letters, dark ink and photos elsewhere on the page stay as they are.
enum Highlighter {
    /// The colours of highlighter pens.
    enum Color: String, Equatable {
        case yellow, green, pink, blue, orange
    }

    /// The colour of a highlighter pixel; hues as measured on a photographed page and own test pages.
    static func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color? {
        guard isHighlight(r, g, b) else { return nil }
        let red = CGFloat(r), green = CGFloat(g), blue = CGFloat(b)
        let brightest = max(red, green, blue), range = brightest - min(red, green, blue)
        var hue: CGFloat
        if brightest == red { hue = 60 * (green - blue) / range } else if brightest == green { hue = 60 * (blue - red) / range + 120 } else { hue = 60 * (red - green) / range + 240 }
        if hue < 0 { hue += 360 }
        switch hue {
        case 15..<42: return .orange
        case 42..<75: return .yellow
        case 75..<165: return .green
        case 165..<265: return .blue
        default: return .pink
        }
    }

    /// The lines with the highlighter colour of each word. A word counts as marked when at least half of the paper around
    /// its letters has the colour (the letters themselves are left out, or bold words would fall short) and it lies in
    /// a highlighted band, so that coloured letters on white paper count as nothing. Someone marking a whole line often starts a
    /// little late: a short word at the end of a line in which all the others are marked counts too ("4." before a heading).
    static func marked(_ lines: [TextRecognizer.Line], in image: CGImage) -> [TextRecognizer.Line] {
        let width = image.width, height = image.height
        guard width >= 16, height >= 16,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return lines }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let bands = highlightedCells(pixels: pixels, width: width, height: height)
        guard !bands.rects.isEmpty else { return lines }
        func mark(_ box: CGRect) -> Color? {
            // Rows from the top, Vision's boxes from the bottom.
            let rect = CGRect(x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height), width: box.width * CGFloat(width), height: box.height * CGFloat(height))
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rect.isEmpty else { return nil }
            let column = Int(rect.midX) / bands.cell, row = Int(rect.midY) / bands.cell
            guard bands.rects.contains(where: { column >= $0.minX && column <= $0.maxX && row >= $0.minY && row <= $0.maxY }) else { return nil }
            var counts: [Color: Int] = [:], paper = 0
            for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
                for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
                    let i = (y * width + x) * 4
                    guard max(pixels[i], pixels[i + 1], pixels[i + 2]) >= letterBelow else { continue }
                    paper += 1
                    if let found = color(pixels[i], pixels[i + 1], pixels[i + 2]) { counts[found, default: 0] += 1 }
                }
            }
            guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 >= paper else { return nil }
            return top.key
        }
        return lines.map { line in
            var line = line
            line.words = fillingEnds(line.words.map { TextRecognizer.Line.Word(text: $0.text, box: $0.box, highlight: mark($0.box)) })
            return line
        }
    }

    /// A short word at the start or end of a line, or one between two marked words, takes the colour when all others have one and the same.
    static func fillingEnds(_ words: [TextRecognizer.Line.Word]) -> [TextRecognizer.Line.Word] {
        let colors = Set(words.compactMap(\.highlight))
        guard words.count >= 3, colors.count == 1, let color = colors.first else { return words }
        let bare = words.indices.filter { words[$0].highlight == nil }
        guard bare.count <= 2, bare.allSatisfy({ index in
            index == 0 || index == words.count - 1 ? words[index].text.count <= 3 : words[index - 1].highlight != nil && words[index + 1].highlight != nil
        }) else { return words }
        return words.map { TextRecognizer.Line.Word(text: $0.text, box: $0.box, highlight: color) }
    }

    /// The picture with the highlighter colour taken out, or nil when there is no highlighted band (then nothing changes).
    static func cleaned(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width >= 16, height >= 16,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let bands = highlightedCells(pixels: pixels, width: width, height: height)
        guard !bands.rects.isEmpty else { return nil }
        let cell = bands.cell
        for rect in bands.rects {
            for y in (rect.minY * cell)..<min(height, (rect.maxY + 1) * cell) {
                for x in (rect.minX * cell)..<min(width, (rect.maxX + 1) * cell) {
                    let i = (y * width + x) * 4
                    let brightest = max(pixels[i], pixels[i + 1], pixels[i + 2])
                    pixels[i] = brightest
                    pixels[i + 1] = brightest
                    pixels[i + 2] = brightest
                }
            }
        }
        return context.makeImage()
    }

    /// Pixels at least this bright are paper or marker; darker ones are letters.
    private static let letterBelow: UInt8 = 110

    /// A highlighter colour: clearly coloured and not dark; grey paper is not coloured, black ink is dark. Red and blue ink
    /// are bright in one channel only (217, 25, 25), a marker in two (pink 237, 28, 140; yellow, orange, light blue).
    /// Only green is bright in one channel (about 10, 210, 0 in a photo); green ink is rare. On a photo the same marker
    /// gets much darker where the light falls off, and the paper too (a photographed page: yellow from 192, 171, 32 to 150, 133, 35,
    /// green from 151, 210, 118 to 100, 160, 72, paper 141, 132, 117), so what counts is how coloured it is, not how bright.
    static func isHighlight(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let channels = [Int(r), Int(g), Int(b)].sorted()
        let brightest = channels[2], second = channels[1], darkest = channels[0]
        guard brightest >= Int(letterBelow), (brightest - darkest) * 100 >= brightest * 35 else { return false }
        return second * 100 >= brightest * 45 || (Int(g) == brightest && brightest >= 190)
    }

    /// The highlighted bands as rectangles of cells (inclusive, one cell of margin), and the cell size in pixels. A cell is
    /// highlighted when most of what is not a letter in it has the colour. A band is a group of such cells at least 8 cells
    /// wide and much longer than thick; across it (column by column, so a slanted band on a photo counts in full, its box
    /// would be mostly empty) it is 60 % filled. Cells two apart along a line still belong together: a thick letter can
    /// take a whole cell (measured on a photographed page: the marked lines fell into pieces and were not found).
    static func highlightedCells(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int)
        -> (cell: Int, rects: [(minX: Int, minY: Int, maxX: Int, maxY: Int)]) {
        let cell = max(4, min(width, height) / 300)
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var marked = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var count = 0, samples = 0, paper = 0
                // Every second pixel in both directions is enough to judge a cell.
                for y in stride(from: row * cell, to: min(height, (row + 1) * cell), by: 2) {
                    for x in stride(from: column * cell, to: min(width, (column + 1) * cell), by: 2) {
                        let i = (y * width + x) * 4
                        samples += 1
                        if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= letterBelow { paper += 1 }
                        if isHighlight(pixels[i], pixels[i + 1], pixels[i + 2]) { count += 1 }
                    }
                }
                marked[row * columns + column] = paper * 4 >= samples && count * 100 >= paper * 60
            }
        }
        var seen = [Bool](repeating: false, count: marked.count)
        var rects: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
        for start in marked.indices where marked[start] && !seen[start] {
            var stack = [start], minX = columns, maxX = 0, minY = rows, maxY = 0, count = 0
            var spans: [Int: (low: Int, high: Int)] = [:]
            seen[start] = true
            while let current = stack.popLast() {
                let x = current % columns, y = current / columns
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                spans[x] = (min(spans[x]?.low ?? y, y), max(spans[x]?.high ?? y, y))
                for dy in -1...1 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < columns, ny < rows, dx != 0 || dy != 0 else { continue }
                        let next = ny * columns + nx
                        if marked[next] && !seen[next] { seen[next] = true; stack.append(next) }
                    }
                }
            }
            let w = maxX - minX + 1
            let across = spans.values.map { $0.high - $0.low + 1 }.reduce(0, +)
            guard w >= 8, across >= 2 * spans.count, w * spans.count >= 3 * across, count * 100 >= across * 60 else { continue }
            rects.append((max(0, minX - 1), max(0, minY - 1), min(columns - 1, maxX + 1), min(rows - 1, maxY + 1)))
        }
        return (cell, rects)
    }
}

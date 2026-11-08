import Foundation

/// A PowerPoint file (.pptx) with one picture per slide, written with the app's own code. Used for PDF → PPTX: each page
/// becomes a slide showing that page as a picture. The slides have the shape of the first page; other
/// pages are fitted in, centered.
enum SlideDeck {
    struct Slide: Equatable {
        var picture: Data
        var isJPEG: Bool
        /// The picture's size in points (its page's size).
        var size: CGSize
    }

    /// One point is 12 700 EMU, the unit of PowerPoint files.
    static func emu(_ points: CGFloat) -> Int { Int((points * 12_700).rounded()) }

    static func write(_ slides: [Slide], to destination: URL) async throws {
        guard let first = slides.first else { throw AppError.invalidInput(tr("There are no pages to put on slides.", "Es gibt keine Seiten, die auf Folien kommen könnten.")) }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("twistel-pptx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        for folder in ["_rels", "docProps", "ppt/_rels", "ppt/slides/_rels", "ppt/slideLayouts/_rels", "ppt/slideMasters/_rels", "ppt/theme", "ppt/media"] {
            try fm.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // PowerPoint accepts slides from 1 to 56 inches on a side.
        let slideSize = CGSize(width: min(max(first.size.width, 72), 4032), height: min(max(first.size.height, 72), 4032))
        let parts = xmlParts(slides, slideSize: slideSize)
        var entries = parts.map(\.0)
        for (index, slide) in slides.enumerated() {
            let name = "ppt/media/image\(index + 1).\(slide.isJPEG ? "jpg" : "png")"
            try slide.picture.write(to: staging.appendingPathComponent(name))
            entries.append(name)
        }
        for (name, content) in parts { try content.write(to: staging.appendingPathComponent(name), atomically: false, encoding: .utf8) }
        try await ZipTool.zipOrdered(directory: staging, entries: entries, to: destination)
    }

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let namespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    private static let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"

    /// The XML parts, `[Content_Types].xml` first.
    static func xmlParts(_ slides: [Slide], slideSize: CGSize) -> [(String, String)] {
        let contentTypes = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/><Default Extension=\"png\" ContentType=\"image/png\"/>"
            + "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
            + "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
            + "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
            + "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
            + slides.indices.map { "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined()
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
            + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/></Types>"
        let rootRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relType)/officeDocument\" Target=\"ppt/presentation.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
            + "<Relationship Id=\"rId3\" Type=\"\(relType)/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>"
        let core = header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title></dc:title></cp:coreProperties>"
        let app = header + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>\(AppIdentity.name)</Application>"
            + "<Slides>\(slides.count)</Slides></Properties>"
        let presentation = header + "<p:presentation \(namespaces) saveSubsetFonts=\"1\">"
            + "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>"
            + slides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 3)\"/>" }.joined()
            + "</p:sldIdLst><p:sldSz cx=\"\(emu(slideSize.width))\" cy=\"\(emu(slideSize.height))\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        let presentationRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relType)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(relType)/theme\" Target=\"theme/theme1.xml\"/>"
            + slides.indices.map { "<Relationship Id=\"rId\($0 + 3)\" Type=\"\(relType)/slide\" Target=\"slides/slide\($0 + 1).xml\"/>" }.joined()
            + "</Relationships>"
        let master = header + "<p:sldMaster \(namespaces)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld>"
            + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" "
            + "accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>"
        let masterRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relType)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(relType)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>"
        let layout = header + "<p:sldLayout \(namespaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(emptyTree)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        let layoutRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relType)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"
        var parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypes), ("_rels/.rels", rootRels), ("docProps/core.xml", core), ("docProps/app.xml", app),
            ("ppt/presentation.xml", presentation), ("ppt/_rels/presentation.xml.rels", presentationRels),
            ("ppt/slideMasters/slideMaster1.xml", master), ("ppt/slideMasters/_rels/slideMaster1.xml.rels", masterRels),
            ("ppt/slideLayouts/slideLayout1.xml", layout), ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", layoutRels),
            ("ppt/theme/theme1.xml", header + theme),
        ]
        for (index, slide) in slides.enumerated() {
            // Fitted into the slide, centered.
            let scale = min(slideSize.width / max(slide.size.width, 1), slideSize.height / max(slide.size.height, 1))
            let size = CGSize(width: slide.size.width * scale, height: slide.size.height * scale)
            let origin = CGPoint(x: (slideSize.width - size.width) / 2, y: (slideSize.height - size.height) / 2)
            let xml = header + "<p:sld \(namespaces)><p:cSld><p:spTree>\(emptyTree)"
                + "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(index + 1)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"
                + "<p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
                + "<p:spPr><a:xfrm><a:off x=\"\(emu(origin.x))\" y=\"\(emu(origin.y))\"/><a:ext cx=\"\(emu(size.width))\" cy=\"\(emu(size.height))\"/></a:xfrm>"
                + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
                + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            let rels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relType)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(relType)/image\" Target=\"../media/image\(index + 1).\(slide.isJPEG ? "jpg" : "png")\"/></Relationships>"
            parts += [("ppt/slides/slide\(index + 1).xml", xml), ("ppt/slides/_rels/slide\(index + 1).xml.rels", rels)]
        }
        return parts
    }

    /// The smallest complete theme: colours, fonts and the three-step fill, line and effect styles every theme must have.
    private static let theme = """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office"><a:themeElements>\
    <a:clrScheme name="Office"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1>\
    <a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4>\
    <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink>\
    <a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """
}

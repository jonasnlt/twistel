import Foundation

enum ToolArity {
    case single
    case multiple
    case any
}

enum ToolID: String, CaseIterable, Identifiable {
    case compress
    case editMetadata
    case recognizeText
    case readQR
    case editImage
    case frameImage
    case cropImage
    case redactImage
    case resizeImage
    case rotateImage
    case createPDF
    case createCollage
    case trimVideo
    case cropVideo
    case changeVideoSpeed
    case joinVideos
    case videoSnapshots
    case splitVideo
    case redactVideo
    case normalizeAudio
    case audioToVideo
    case trimAudio
    case audioChannels
    case redactAudio
    case transcribe
    case mergePDF
    case organizePDF
    case splitPDF
    case extractImages
    case pdfPassword
    case watermarkPDF
    case pageNumbersPDF
    case socialMedia
    case removeBackground
    case videoPresets
    case pdfArchive
    case redactPDF
    case annotate
    case signPDF
    case comparePDF
    case burnSubtitles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return tr("Compress", "Verkleinern")
        case .editMetadata: return tr("Edit metadata", "Metadaten bearbeiten")
        case .recognizeText: return tr("Recognize text", "Text erkennen")
        case .readQR: return tr("Read QR codes", "QR-Codes lesen")
        case .editImage: return tr("Edit photo", "Foto bearbeiten")
        case .frameImage: return tr("Add a background", "Hintergrund hinzufügen")
        case .cropImage: return tr("Crop image", "Bild zuschneiden")
        case .redactImage: return tr("Redact photo", "Foto schwärzen")
        case .resizeImage: return tr("Resize images", "Bildgröße ändern")
        case .rotateImage: return tr("Rotate & flip", "Drehen und spiegeln")
        case .createPDF: return tr("Combine into PDF", "Zu einer PDF zusammenfügen")
        case .createCollage: return tr("Create a collage", "Collage erstellen")
        case .trimVideo: return tr("Trim video", "Video kürzen")
        case .cropVideo: return tr("Crop video", "Video zuschneiden")
        case .changeVideoSpeed: return tr("Change video speed", "Videotempo ändern")
        case .joinVideos: return tr("Join videos", "Videos verbinden")
        case .videoSnapshots: return tr("Save video frames", "Standbilder sichern")
        case .splitVideo: return tr("Split video", "Video aufteilen")
        case .redactVideo: return tr("Redact video", "Video schwärzen")
        case .normalizeAudio: return tr("Normalize volume", "Lautstärke angleichen")
        case .audioToVideo: return tr("Audio visualizer", "Audio visualisieren")
        case .trimAudio: return tr("Trim audio", "Audio kürzen")
        case .audioChannels: return tr("Audio channels", "Audiokanäle")
        case .redactAudio: return tr("Bleep audio", "Audio zensieren")
        case .transcribe: return tr("Transcribe", "Transkribieren")
        case .mergePDF: return tr("Merge PDFs", "PDFs verbinden")
        case .organizePDF: return tr("Organize PDF pages", "PDF-Seiten ordnen")
        case .splitPDF: return tr("Split PDF", "PDF aufteilen")
        case .extractImages: return tr("Extract images", "Bilder herausziehen")
        case .pdfPassword: return tr("PDF password", "PDF-Passwort")
        case .watermarkPDF: return tr("Add watermark", "Wasserzeichen hinzufügen")
        case .pageNumbersPDF: return tr("Add page numbers", "Seitenzahlen hinzufügen")
        case .socialMedia: return tr("Social media & sending", "Social Media & Versenden")
        case .removeBackground: return tr("Cut out subject", "Freistellen")
        case .videoPresets: return tr("Video for social media", "Video für Social Media")
        case .pdfArchive: return tr("Archive as PDF/A", "Als PDF/A archivieren")
        case .redactPDF: return tr("Redact PDF", "PDF schwärzen")
        case .annotate: return tr("Annotate", "Annotieren")
        case .signPDF: return tr("Sign PDF", "PDF unterschreiben")
        case .comparePDF: return tr("Compare PDFs", "PDFs vergleichen")
        case .burnSubtitles: return tr("Burn in subtitles", "Untertitel einbrennen")
        }
    }

    var progressTitle: String {
        switch self {
        case .compress: return tr("Compressing", "Wird verkleinert")
        case .editMetadata: return tr("Editing metadata", "Metadaten werden bearbeitet")
        case .recognizeText: return tr("Recognizing text", "Text wird erkannt")
        case .readQR: return tr("Reading QR codes", "QR-Codes werden gelesen")
        case .editImage: return tr("Editing photo", "Foto wird bearbeitet")
        case .frameImage: return tr("Adding background", "Hintergrund wird hinzugefügt")
        case .cropImage, .cropVideo: return tr("Cropping", "Wird zugeschnitten")
        case .redactImage, .redactVideo, .redactPDF: return tr("Redacting", "Wird geschwärzt")
        case .resizeImage: return tr("Resizing", "Größe wird geändert")
        case .rotateImage: return tr("Rotating", "Wird gedreht")
        case .createPDF: return tr("Creating PDF", "PDF wird erstellt")
        case .createCollage: return tr("Creating collage", "Collage wird erstellt")
        case .trimVideo, .trimAudio: return tr("Trimming", "Wird gekürzt")
        case .changeVideoSpeed: return tr("Changing speed", "Tempo wird geändert")
        case .joinVideos: return tr("Joining", "Wird verbunden")
        case .videoSnapshots: return tr("Saving frames", "Standbilder werden gesichert")
        case .splitVideo, .splitPDF: return tr("Splitting", "Wird aufgeteilt")
        case .normalizeAudio: return tr("Normalizing", "Lautstärke wird angeglichen")
        case .audioToVideo: return tr("Creating visualizer", "Visualisierung wird erstellt")
        case .audioChannels: return tr("Converting channels", "Kanäle werden umgewandelt")
        case .redactAudio: return tr("Bleeping", "Wird zensiert")
        case .transcribe: return tr("Transcribing", "Wird transkribiert")
        case .mergePDF: return tr("Merging", "Wird verbunden")
        case .organizePDF: return tr("Organizing", "Seiten werden geordnet")
        case .extractImages: return tr("Extracting images", "Bilder werden herausgezogen")
        case .pdfPassword: return tr("PDF password", "PDF-Passwort")
        case .watermarkPDF: return tr("Adding watermark", "Wasserzeichen wird hinzugefügt")
        case .pageNumbersPDF: return tr("Numbering pages", "Seiten werden nummeriert")
        case .socialMedia: return tr("Preparing picture", "Bild wird vorbereitet")
        case .removeBackground: return tr("Removing background", "Hintergrund wird entfernt")
        case .videoPresets: return tr("Preparing video", "Video wird vorbereitet")
        case .pdfArchive: return tr("Saving as PDF/A", "Wird als PDF/A gesichert")
        case .annotate: return tr("Annotating", "Wird annotiert")
        case .signPDF: return tr("Signing", "Wird unterschrieben")
        case .comparePDF: return tr("Comparing", "Wird verglichen")
        case .burnSubtitles: return tr("Burning in subtitles", "Untertitel werden eingebrannt")
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .editMetadata: return "tag"
        case .recognizeText: return "text.viewfinder"
        case .readQR: return "qrcode.viewfinder"
        case .editImage: return "slider.horizontal.3"
        case .frameImage: return "photo.artframe"
        case .cropImage, .cropVideo: return "crop"
        case .redactImage, .redactPDF: return "eye.slash"
        case .redactVideo: return "video.slash"
        case .resizeImage: return "arrow.up.left.and.arrow.down.right"
        case .rotateImage: return "rotate.right"
        case .createPDF: return "doc.richtext"
        case .createCollage: return "square.grid.2x2"
        case .trimVideo, .trimAudio: return "scissors"
        case .changeVideoSpeed: return "gauge.with.dots.needle.67percent"
        case .joinVideos: return "link"
        case .videoSnapshots: return "camera.viewfinder"
        case .splitVideo: return "rectangle.split.2x1"
        case .splitPDF: return "doc.on.doc"
        case .normalizeAudio: return "waveform"
        case .audioToVideo: return "waveform.and.magnifyingglass"
        case .audioChannels: return "headphones"
        case .redactAudio: return "speaker.slash"
        case .transcribe: return "text.bubble"
        case .mergePDF: return "doc.on.doc.fill"
        case .organizePDF: return "rectangle.stack"
        case .extractImages: return "photo.on.rectangle.angled"
        case .pdfPassword: return "lock.doc"
        case .watermarkPDF: return "seal"
        case .pageNumbersPDF: return "number"
        case .socialMedia: return "person.crop.rectangle"
        case .removeBackground: return "lasso"
        case .videoPresets: return "person.crop.rectangle"
        case .pdfArchive: return "archivebox"
        case .annotate: return "pencil.tip.crop.circle"
        case .signPDF: return "signature"
        case .comparePDF: return "doc.text.magnifyingglass"
        case .burnSubtitles: return "captions.bubble"
        }
    }

    var categories: Set<FormatCategory> {
        switch self {
        case .compress, .editMetadata:
            return [.image, .video, .audio, .document]
        case .recognizeText, .readQR, .annotate:
            return [.image, .document]
        case .editImage, .frameImage, .cropImage, .redactImage, .resizeImage, .rotateImage, .createPDF, .createCollage, .socialMedia, .removeBackground:
            return [.image]
        case .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos, .videoSnapshots, .splitVideo, .redactVideo, .videoPresets, .burnSubtitles:
            return [.video]
        case .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio:
            return [.audio]
        case .transcribe:
            return [.audio, .video]
        case .mergePDF, .organizePDF, .splitPDF, .extractImages, .pdfPassword, .watermarkPDF, .pageNumbersPDF, .pdfArchive, .redactPDF, .signPDF, .comparePDF:
            return [.document]
        }
    }

    var arity: ToolArity {
        switch self {
        case .compress, .editMetadata, .resizeImage, .rotateImage, .createPDF, .transcribe, .extractImages, .recognizeText, .readQR, .pdfPassword, .watermarkPDF, .pageNumbersPDF, .socialMedia, .removeBackground, .videoPresets, .pdfArchive, .comparePDF: return .any
        case .createCollage, .joinVideos, .mergePDF: return .multiple
        default: return .single
        }
    }

    func applies(to formats: [FileFormat]) -> Bool {
        guard !formats.isEmpty else { return false }
        let categories = Set(formats.map(\.category))
        guard categories.count == 1, let category = categories.first, self.categories.contains(category) else { return false }
        if category == .document {
            switch self {
            case .mergePDF, .organizePDF, .splitPDF, .editMetadata, .compress, .extractImages, .recognizeText, .readQR, .pdfPassword, .watermarkPDF, .pageNumbersPDF, .pdfArchive, .redactPDF, .annotate, .signPDF, .comparePDF:
                guard formats.allSatisfy({ $0 == .pdf }) else { return false }
            default:
                return false
            }
        }
        // One now and the other chosen in the window, or both at once.
        if self == .comparePDF, formats.count > 2 { return false }
        if category == .video, formats.contains(.gif), self != .compress, self != .editMetadata { return false }
        switch arity {
        case .single: return formats.count == 1
        case .multiple: return formats.count >= 2
        case .any: return true
        }
    }

    static func available(for formats: [FileFormat]) -> [ToolID] {
        allCases.filter { $0.applies(to: formats) }
    }

    static var total: Int { allCases.count }
}

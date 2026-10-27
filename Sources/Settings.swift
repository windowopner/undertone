import Foundation
import Combine

enum VisualStyle: String, CaseIterable {
    case bars, weave, contour, cutout, orbit, field, aurora, pulse, image

    var title: String {
        switch self {
        case .bars: return "3D 막대"
        case .weave: return "소리의 천"
        case .contour: return "물결 선"
        case .cutout: return "컷아웃"
        case .orbit: return "궤도"
        case .field: return "색면"
        case .aurora: return "오로라"
        case .pulse: return "펄스"
        case .image: return "내 이미지"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var style: VisualStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var imagePath: String? { didSet { d.set(imagePath, forKey: "imagePath") } }
    @Published var sensitivity: Double { didSet { d.set(sensitivity, forKey: "sensitivity") } }
    @Published var launchCompanions: Bool { didSet { d.set(launchCompanions, forKey: "launchCompanions") } }
    @Published var companionApps: [String] { didSet { d.set(companionApps, forKey: "companionApps") } }
    @Published var startFullscreen: Bool { didSet { d.set(startFullscreen, forKey: "startFullscreen") } }
    @Published var matchAlbum: Bool { didSet { d.set(matchAlbum, forKey: "matchAlbum") } }

    private init() {
        style = VisualStyle(rawValue: d.string(forKey: "style") ?? "") ?? .aurora
        imagePath = d.string(forKey: "imagePath")
        let s = d.double(forKey: "sensitivity")
        sensitivity = s == 0 ? 1.0 : s
        launchCompanions = d.object(forKey: "launchCompanions") as? Bool ?? true
        companionApps = d.stringArray(forKey: "companionApps") ?? ["Verci", "Lumn"]
        startFullscreen = d.bool(forKey: "startFullscreen")
        matchAlbum = d.object(forKey: "matchAlbum") as? Bool ?? true
    }
}

/// Per-window flag so a hidden wallpaper can drop to a low frame rate.
final class WindowVisibility: ObservableObject {
    @Published var visible = true
}

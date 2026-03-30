//
//  Defaults.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

enum StatusBarDisplayMode: Int, CaseIterable {
    case icon = 0
    case text = 1
    case compact = 2

    var label: String {
        switch self {
        case .icon: return "Icon"
        case .text: return "Full"
        case .compact: return "Compact"
        }
    }
}

class Defaults: ObservableObject {
    static let shared = Defaults()
    private let kUserPreferIconStatusBarItem = "com.vincent-neo.LosslessSwitcher-Key-UserPreferIconStatusBarItem"
    private let kStatusBarDisplayMode = "com.vincent-neo.LosslessSwitcher-Key-StatusBarDisplayMode"
    private let kSelectedDeviceUID = "com.vincent-neo.LosslessSwitcher-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.vincent-neo.LosslessSwitcher-Key-BitDepthDetection"
    private let kUserPreferDebugMenu = "com.vincent-neo.LosslessSwitcher-Key-DebugMenu"
    private let kShellScriptPath = "KeyShellScriptPath"

    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferBitDepthDetection : false,
            kUserPreferDebugMenu : false
        ])

        // Migrate from old boolean preference to new display mode enum
        if let rawMode = UserDefaults.standard.object(forKey: kStatusBarDisplayMode) as? Int,
           let mode = StatusBarDisplayMode(rawValue: rawMode) {
            statusBarDisplayMode = mode
        } else {
            let oldPrefersIcon = UserDefaults.standard.object(forKey: kUserPreferIconStatusBarItem) as? Bool ?? true
            statusBarDisplayMode = oldPrefersIcon ? .icon : .text
        }

        self.userPreferBitDepthDetection = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDetection)
        self.userPreferDebugMenu = UserDefaults.standard.bool(forKey: kUserPreferDebugMenu)
    }

    @Published var statusBarDisplayMode: StatusBarDisplayMode {
        willSet {
            UserDefaults.standard.set(newValue.rawValue, forKey: kStatusBarDisplayMode)
        }
    }
    
    var selectedDeviceUID: String? {
        get {
            return UserDefaults.standard.string(forKey: kSelectedDeviceUID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kSelectedDeviceUID)
        }
    }
    
    var shellScriptPath: String? {
        get {
            return UserDefaults.standard.string(forKey: kShellScriptPath)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: kShellScriptPath)
        }
    }
    
    @Published var userPreferBitDepthDetection: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferBitDepthDetection)
        }
    }

    @Published var userPreferDebugMenu: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferDebugMenu)
        }
    }
    
}

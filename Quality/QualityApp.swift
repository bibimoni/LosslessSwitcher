//
//  QualityApp.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI

@main
struct QualityApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject private var controller = MenuBarController()
    @ObservedObject private var defaults = Defaults.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller.outputDevices)
                .environmentObject(defaults)
        } label: {
            switch defaults.statusBarDisplayMode {
            case .icon:
                Image(systemName: "music.note")
                    .padding(.horizontal, 8)
            case .text:
                SampleRateLabel(compact: false)
                    .environmentObject(controller.outputDevices)
            case .compact:
                SampleRateLabel(compact: true)
                    .environmentObject(controller.outputDevices)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

//
//  FindMyCatClientApp.swift
//  FindMyCatClient
//
//  Created for FindMyCat macOS client
//

import SwiftUI

@main
struct FindMyCatClientApp: App {
    @StateObject private var viewModel = MainViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}

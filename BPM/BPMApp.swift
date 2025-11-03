//
//  BPMApp.swift
//  BPM
//
//  Created by Alexander Kvamme on 11/2/25.
//

import SwiftUI

@main
struct BPMApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

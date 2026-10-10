//
//  UpdaterController.swift
//  Face ID for Mac (by PK)
//
//  Sparkle removed on purpose: this build never talks to the network and never replaces itself with someone else's
//  build. The type keeps its old surface so the rest of the app compiles unchanged; every member is inert.
//

import Observation

@Observable
@MainActor
final class UpdaterController {
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    let isPresentingUpdateUI = false

    func start() {}
    func checkForUpdates() {}
}

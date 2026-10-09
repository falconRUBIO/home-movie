import SwiftUI

@main struct HomeMovieApp: App {
    @StateObject private var app = AppModel()
    var body: some SwiftUI.Scene {
        WindowGroup { LibraryView().environmentObject(app) }
    }
}

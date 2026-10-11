import SwiftUI

@main struct HomeMovieApp: App {
    @UIApplicationDelegateAdaptor(MovieAppDelegate.self) private var delegate
    @StateObject private var app = AppModel()
    var body: some SwiftUI.Scene {
        WindowGroup { LibraryView().environmentObject(app) }
    }
}

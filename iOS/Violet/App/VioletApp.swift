import MWDATCore
import SwiftUI

@main
struct VioletApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model: AppModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[Violet] Wearables configuration failed: \(error.localizedDescription)")
      #endif
    }
    _model = State(initialValue: AppModel())
  }

  var body: some Scene {
    WindowGroup {
      HomeView(model: model)
        .task { await model.start() }
        .onOpenURL { url in
          Task { await model.handleCallbackURL(url) }
        }
        .onChange(of: scenePhase) { _, newPhase in
          model.setActive(newPhase == .active)
        }
    }
  }
}

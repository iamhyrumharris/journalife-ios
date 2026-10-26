import JournalUI
import SwiftUI

/// The shared top bar on every tab root: + on the left, the tab title in the middle,
/// Settings and a tab-specific ••• menu on the right.
struct TabRootToolbar<MenuContent: View>: ViewModifier {
    let title: LocalizedStringResource
    @ViewBuilder var menu: () -> MenuContent

    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    // Sync status button goes here in Phase 3 (hidden until sync exists).
                    Button {
                        app.createEntry()
                    } label: {
                        Label("New Entry", systemImage: "plus")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        app.isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    if MenuContent.self != EmptyView.self {
                        Menu {
                            menu()
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                    }
                }
            }
    }
}

extension View {
    func tabRootToolbar(title: LocalizedStringResource) -> some View {
        modifier(TabRootToolbar(title: title) { EmptyView() })
    }

    func tabRootToolbar<MenuContent: View>(title: LocalizedStringResource, @ViewBuilder menu: @escaping () -> MenuContent) -> some View {
        modifier(TabRootToolbar(title: title, menu: menu))
    }
}

extension View {
    /// A frosted header (blur plus page color) with a hairline under it, instead of the default
    /// see-through edge, so scrolled rows don't show behind the title and buttons. (The calendar draws its
    /// own under the weekday row.)
    func solidNavigationHeader() -> some View {
        scrollEdgeEffectHidden(true, for: .top)
            .safeAreaBar(edge: .top) {
                Color.clear
                    .frame(height: 0)
                    .background { HeaderBackground().ignoresSafeArea(edges: .top) }
                    .overlay(alignment: .bottom) { Divider() }
            }
    }
}

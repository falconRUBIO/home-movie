import SwiftUI

struct RecentlyDeletedView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var deletingMovies: Set<UUID> = []
    @State private var deletingScenes: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var problem: String?
    @State private var notice: String?

    private struct Item: Identifiable {
        let id: UUID
        let movie: Movie
        let scene: Scene?
        var title: String { movie.name }
        var detail: String { scene.map { "Scene · \($0.capturedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "Movie · \(movie.scenes.count) scenes" }
    }
    private var items: [Item] {
        app.movies.flatMap { movie -> [Item] in
            if movie.deletedAt != nil { return [Item(id: movie.id, movie: movie, scene: nil)] }
            return movie.scenes.filter { $0.deletedAt != nil }.map { Item(id: $0.id, movie: movie, scene: $0) }
        }
    }
    private func targets(_ ids: Set<UUID>) -> (movies: Set<UUID>, scenes: Set<UUID>) {
        let chosen = items.filter { ids.contains($0.id) }
        return (Set(chosen.filter { $0.scene == nil }.map(\.movie.id)), Set(chosen.compactMap { $0.scene?.id }))
    }
    private func requestDelete(_ ids: Set<UUID>) {
        let value = targets(ids)
        deletingMovies = value.movies; deletingScenes = value.scenes; confirmDelete = true
    }
    private func restore(_ ids: Set<UUID>) {
        let value = targets(ids)
        busy = true
        Task {
            defer { busy = false }
            do {
                try await app.store.restoreDeleted(movieIDs: value.movies, sceneIDs: value.scenes)
                await app.refresh(); selected.subtract(ids)
            } catch { problem = error.localizedDescription }
        }
    }
    @ViewBuilder private func actions(_ item: Item) -> some View {
        Button("Restore", systemImage: "arrow.uturn.backward") { restore([item.id]) }
        Button("Delete Permanently", systemImage: "trash", role: .destructive) { requestDelete([item.id]) }
    }
    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(item.id) ? Color.accentColor : .secondary)
                    .font(.title2).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Recently Deleted Items", systemImage: "trash", description: Text("Deleted movies and scenes appear here."))
            } else {
                List {
                    Section {
                        ForEach(items) { item in
                            Group {
                                if selecting {
                                    Button {
                                        if !selected.insert(item.id).inserted { selected.remove(item.id) }
                                    } label: { row(item) }.tint(.primary)
                                        .accessibilityAddTraits(selected.contains(item.id) ? [.isSelected] : [])
                                        .accessibilityValue(selected.contains(item.id) ? "Selected" : "Not selected")
                                } else {
                                    HStack {
                                        row(item)
                                        Menu { actions(item) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                                            .accessibilityLabel("Manage \(item.title), \(item.detail)")
                                    }
                                    .contextMenu { actions(item) }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button("Restore", systemImage: "arrow.uturn.backward") { restore([item.id]) }.tint(.blue)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("Delete", systemImage: "trash") { requestDelete([item.id]) }.tint(.red)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Items stay here until you restore or permanently delete them. Copies in Photos, Files, and backups are separate.")
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy { ProgressView().accessibilityLabel("Updating Recently Deleted") }
                else { Button(selecting ? "Done" : "Select") { selecting.toggle(); selected = [] }.disabled(items.isEmpty) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting && !items.isEmpty {
                VStack(spacing: 0) {
                    Button(selected.count == items.count ? "Deselect All" : "Select All") {
                        selected = selected.count == items.count ? [] : Set(items.map(\.id))
                    }.frame(minHeight: 44)
                    HStack {
                        Button("Restore") { restore(selected) }
                        Spacer()
                        Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete", role: .destructive) { requestDelete(selected) }
                    }.frame(minHeight: 44).disabled(selected.isEmpty)
                }.padding(.horizontal, 20).background(.bar).disabled(busy)
            }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            selected.formIntersection(ids)
            if ids.isEmpty { selecting = false }
        }
        .alert("Delete Permanently?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Permanently", role: .destructive) {
                let movies = deletingMovies, scenes = deletingScenes
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let pending = try await app.store.permanentlyDelete(movieIDs: movies, sceneIDs: scenes)
                        await app.refresh(); selected = []
                        if pending > 0 { notice = "Items were removed. Some files could not be deleted yet; Home Movie will retry when reopened." }
                    } catch { problem = error.localizedDescription }
                }
            }
        } message: {
            Text("\(deletingMovies.count + deletingScenes.count) selected items and their original recordings will be deleted from Home Movie. This cannot be undone. Copies in Photos, Files, and backups remain.")
        }
        .alert("Couldn’t Complete Action", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .alert("File Cleanup Pending", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
    }
}

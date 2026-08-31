import SwiftUI

struct FindBarView: View {
    @ObservedObject var state: BrowserWindowState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("在网页中查找", text: $state.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    state.selectedTab?.find(state.findQuery)
                }
            Button("上一个") {
                state.selectedTab?.find(state.findQuery, backwards: true)
            }
            .buttonStyle(.borderless)
            Button("下一个") {
                state.selectedTab?.find(state.findQuery)
            }
            .buttonStyle(.borderless)
            Button {
                state.setFindBar(visible: false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: state.findQuery) { _, value in
            state.selectedTab?.find(value)
        }
    }
}

struct StatusBarView: View {
    @ObservedObject var state: BrowserWindowState

    var body: some View {
        HStack {
            Text(state.selectedTab?.hoveredLink ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let zoom = state.selectedTab?.pageZoom, abs(zoom - 1) > 0.01 {
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .onTapGesture {
                        state.selectedTab?.resetZoom()
                    }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: (state.selectedTab?.hoveredLink.isEmpty ?? true) && abs((state.selectedTab?.pageZoom ?? 1) - 1) < 0.01 ? 0 : 22)
        .clipped()
        .background(.bar)
    }
}

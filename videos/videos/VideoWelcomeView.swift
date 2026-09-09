import SwiftUI

struct VideoWelcomeView: View {
    @Binding var hasCompletedInitialSetup: Bool
    @EnvironmentObject var resourceManager: ResourceManager
    @AppStorage("isGlobalEnglishMode") private var en = false

    @State private var goSelect = false
    @State private var ripple = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color.viewBackground, Color.purple.opacity(0.10)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer().frame(height: 40)

                    ZStack {
                        Circle().fill(LinearGradient(colors: [.pink, .purple],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 88, height: 88)
                            .shadow(color: .purple.opacity(0.35), radius: 18, y: 8)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 42, weight: .bold)).foregroundColor(.white)
                    }

                    Text(Localized.welcomeInstruction)
                        .font(.system(size: 26, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 24).padding(.top, 22)

                    channelShowcase.padding(.top, 26)

                    Spacer()
                }

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Button {
                            Task { await resourceManager.refreshServerConfig(minInterval: 0) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 20, weight: .bold)).foregroundColor(.secondary)
                                .frame(width: 50, height: 50)
                                .background(Material.thinMaterial).clipShape(Circle())
                        }
                        .padding(.leading, 30)

                        Spacer()

                        Button { goSelect = true } label: {
                            ZStack {
                                Circle().stroke(Color.purple.opacity(ripple ? 0 : 0.5), lineWidth: 2)
                                    .frame(width: 62, height: 62)
                                    .scaleEffect(ripple ? 1.5 : 1).opacity(ripple ? 0 : 1)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                                    .frame(width: 62, height: 62)
                                    .background(LinearGradient(colors: [.pink, .purple],
                                                               startPoint: .topLeading,
                                                               endPoint: .bottomTrailing))
                                    .clipShape(Circle())
                                    .shadow(color: .purple.opacity(0.4), radius: 8, y: 4)
                            }
                        }
                        .padding(.trailing, 30)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: false)) {
                                ripple.toggle()
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }

                if resourceManager.isLoadingConfig && resourceManager.showcaseChannels.isEmpty {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView().scaleEffect(1.4).tint(.white)
                    }
                }
            }
            .navigationDestination(isPresented: $goSelect) {
                VideoChannelSelectView(isFirstTimeSetup: true) {
                    UserDefaults.standard.set(resourceManager.serverReviewMode,
                                              forKey: "setupCompletedDuringReviewMode")
                    hasCompletedInitialSetup = true
                }
            }
        }
        .tint(.purple)
        .task { await resourceManager.refreshServerConfig(minInterval: 0) }
    }

    private var channelShowcase: some View {
        VStack(spacing: 10) {
            ForEach(Array(resourceManager.showcaseChannels.enumerated()), id: \.offset) { i, raw in
                let parts = raw.components(separatedBy: "|")
                let name = en ? (parts.count > 1 ? parts[1] : parts[0]) : parts[0]
                let c = Self.palette[i % Self.palette.count]
                HStack(spacing: 12) {
                    Rectangle().fill(c).frame(width: 4, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    Text(name).font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(c.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
            }
        }
        .padding(.horizontal, 24)
    }

    static let palette: [Color] = [.pink, .purple, .blue, .orange, .teal, .indigo]
}

// MARK: - 单列频道选择
struct VideoChannelSelectView: View {
    let isFirstTimeSetup: Bool
    var onComplete: (() -> Void)? = nil

    @EnvironmentObject var resourceManager: ResourceManager
    @AppStorage("isGlobalEnglishMode") private var en = false
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    private let storageKey = "selectedVideoCategories"
    private let order = ["vid_movie", "vid_west_drama", "vid_asia_drama", "vid_anime", "vid_show"]

    private var channels: [(key: String, name: String)] {
        let m = resourceManager.videoCategoryMappings
        return order.compactMap { k in
            guard let raw = m[k] else { return nil }
            let p = raw.components(separatedBy: "|")
            return (k, en ? (p.count > 1 ? p[1] : p[0]) : p[0])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(Localized.selectChannelTitle)
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                        Button {
                            withAnimation(.spring()) {
                                if selected.count == channels.count { selected.removeAll() }
                                else { selected = Set(channels.map { $0.key }) }
                            }
                            save()
                        } label: {
                            Text(selected.count == channels.count
                                 ? (en ? "None" : "全不选") : (en ? "All" : "全选"))
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(Color.purple))
                        }
                    }
                    .padding(.top, 8)

                    VStack(spacing: 12) {
                        ForEach(channels, id: \.key) { c in
                            let on = selected.contains(c.key)
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    if on { selected.remove(c.key) } else { selected.insert(c.key) }
                                }
                                save()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(c.name).font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundColor(on ? .purple : .secondary.opacity(0.35))
                                }
                                .padding(.horizontal, 16).padding(.vertical, 18)
                                .background(RoundedRectangle(cornerRadius: 16)
                                    .fill(on ? Color.purple.opacity(0.10) : Color.cardBackground))
                                .overlay(RoundedRectangle(cornerRadius: 16)
                                    .stroke(on ? Color.purple.opacity(0.55) : Color.secondary.opacity(0.12),
                                            lineWidth: on ? 1.5 : 1))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 24)
            }

            VStack(spacing: 0) {
                Divider()
                Button { finish() } label: {
                    Text(selected.isEmpty ? Localized.selectAtLeastOne : Localized.finishSetup)
                        .font(.headline)
                        .foregroundColor(selected.isEmpty ? .secondary : .white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(selected.isEmpty ? Color.secondary.opacity(0.2)
                                                     : Color.purple)
                        .cornerRadius(16)
                }
                .disabled(selected.isEmpty)
                .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 16)
            }
            .background(Material.regular)
        }
        .background(Color.viewBackground.ignoresSafeArea())
        .navigationTitle(en ? "Channels" : "选择频道")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selected = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? []) }
    }

    private func save() { UserDefaults.standard.set(Array(selected), forKey: storageKey) }

    private func finish() {
        save()
        if isFirstTimeSetup { onComplete?() } else { dismiss() }
    }
}

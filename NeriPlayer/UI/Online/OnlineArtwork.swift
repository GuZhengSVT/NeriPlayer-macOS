// OnlineArtwork.swift
// T04: album/playlist artwork view for online surfaces. Loading, empty and failure states stay
// distinct so a broken cover is not indistinguishable from a resource that has no cover at all.
import AppKit
import SwiftUI

struct OnlineArtwork: View {
    enum LoadState: Equatable {
        case empty
        case loading
        case loaded
        case failed(String?)
    }

    let url: URL?
    private let loader: ArtworkImageLoader
    private let cornerRadius: CGFloat
    private let symbolSize: CGFloat

    @State private var state: LoadState = .empty
    @State private var image: NSImage?

    init(url: URL?, loader: ArtworkImageLoader = .shared, cornerRadius: CGFloat = 4, symbolSize: CGFloat = 13) {
        self.url = url
        self.loader = loader
        self.cornerRadius = cornerRadius
        self.symbolSize = symbolSize
        // A memory hit renders on the first frame instead of flashing a placeholder over cached data.
        let cached = loader.cachedImage(for: url)
        _state = State(initialValue: cached == nil ? LoadState.empty : .loaded)
        _image = State(initialValue: cached)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.08))
            switch state {
            case .loaded:
                if let image {
                    GeometryReader { geometry in
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }
            case .loading:
                ProgressView().controlSize(.small)
            case .empty:
                Image(systemName: "music.note").font(.system(size: symbolSize)).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: symbolSize))
                    .foregroundStyle(.secondary)
                    .help(failureMessage ?? "封面加载失败")
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel(accessibilityText)
        .task(id: ArtworkURLNormalizer.taskIdentifier(for: url)) { await reload() }
    }

    private var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private var accessibilityText: Text {
        switch state {
        case .loaded: return Text("封面")
        case .loading: return Text("封面加载中")
        case .empty: return Text("无封面")
        case .failed: return Text(failureMessage ?? "封面加载失败")
        }
    }

    private func reload() async {
        guard let url else {
            image = nil
            state = .empty
            return
        }
        if let cached = loader.cachedImage(for: url) {
            image = cached
            state = .loaded
            return
        }
        image = nil
        state = .loading
        var attempt = 0
        while true {
            do {
                let loaded = try await loader.image(for: url)
                guard !Task.isCancelled else { return }
                image = loaded
                state = .loaded
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Only a transport/HTTP miss is worth retrying: a bad URL or undecodable body is permanent.
                let retryable = (error as? ArtworkLoadFailure).map { $0.isTransient } ?? true
                guard retryable, attempt < 2 else {
                    image = nil
                    state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    return
                }
                attempt += 1
                do { try await Task.sleep(for: .milliseconds(700 * attempt)) } catch { return }
            }
        }
    }
}

import SwiftUI

// MARK: - 법적 문서 식별자

enum LegalDocument: String, CaseIterable {
    case privacy = "privacy-policy"
    case terms   = "terms-of-service"

    var displayTitle: String {
        switch self {
        case .privacy: "개인정보 처리방침"
        case .terms:   "서비스 약관"
        }
    }

    /// 앱 번들 내 리소스 파일명 (확장자 제외)
    var bundleFileName: String { rawValue }

    /// GitHub Pages 공개 URL
    var webURL: URL {
        switch self {
        case .privacy:
            URL(string: "https://jung-geun.github.io/SIFT/privacy-policy.html")!
        case .terms:
            URL(string: "https://jung-geun.github.io/SIFT/terms-of-service.html")!
        }
    }
}

// MARK: - 법적 문서 뷰

struct LegalDocumentView: View {
    let document: LegalDocument

    @State private var content: String = ""
    @State private var loadFailed = false

    var body: some View {
        Group {
            if loadFailed {
                fallbackView
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
                            line.view
                        }
                        webLinkFooter
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle(document.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadContent)
    }

    // MARK: - 파일 로드

    private func loadContent() {
        guard let url = Bundle.main.url(forResource: document.bundleFileName, withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            loadFailed = true
            return
        }
        content = raw
    }

    // MARK: - 파싱

    private var parsedLines: [MarkdownLine] {
        content.components(separatedBy: "\n").map(MarkdownLine.parse)
    }

    // MARK: - 웹 링크 푸터

    private var webLinkFooter: some View {
        VStack(spacing: 12) {
            Divider().padding(.top, 16)
            Link(destination: document.webURL) {
                Label("웹에서 원문 보기", systemImage: "safari")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - 오프라인 폴백

    private var fallbackView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("문서를 불러올 수 없습니다")
                .font(.headline)
            Text("아래 링크에서 웹 버전을 확인해 주세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link(destination: document.webURL) {
                Label("웹에서 보기", systemImage: "safari")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 32)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 마크다운 라인 파서

private enum MarkdownLine {
    case h1(String)
    case h2(String)
    case h3(String)
    case divider
    case bullet(String)
    case tableRow(String)
    case blank
    case body(String)
    case frontMatterMarker  // "---" in YAML front matter → skip

    static func parse(_ raw: String) -> MarkdownLine {
        let line = raw
        if line == "---" || line == "---\n" { return .divider }
        if line.hasPrefix("# ")  { return .h1(String(line.dropFirst(2))) }
        if line.hasPrefix("## ") { return .h2(String(line.dropFirst(3))) }
        if line.hasPrefix("### "){ return .h3(String(line.dropFirst(4))) }
        if line.hasPrefix("- ")  { return .bullet(String(line.dropFirst(2))) }
        if line.hasPrefix("| ")  { return .tableRow(line) }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        return .body(line)
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .h1(let text):
            Text(text)
                .font(.title2.bold())
                .padding(.top, 20)
                .padding(.bottom, 4)

        case .h2(let text):
            Text(text)
                .font(.title3.bold())
                .padding(.top, 16)
                .padding(.bottom, 2)

        case .h3(let text):
            Text(text)
                .font(.headline)
                .padding(.top, 10)
                .padding(.bottom, 1)

        case .divider:
            Divider()
                .padding(.vertical, 8)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .foregroundStyle(.secondary)
                inlineText(text)
            }
            .padding(.vertical, 1)

        case .tableRow(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 1)

        case .blank:
            Spacer().frame(height: 6)

        case .body(let text):
            inlineText(text)
                .padding(.vertical, 2)

        case .frontMatterMarker:
            EmptyView()
        }
    }

    @ViewBuilder
    private func inlineText(_ raw: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.body)
        } else {
            Text(raw)
                .font(.body)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        LegalDocumentView(document: .privacy)
    }
}

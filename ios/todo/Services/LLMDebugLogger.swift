import Foundation

enum LLMDebugLogger {
    #if DEBUG
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PIEROOT_LLM_DEBUG"] == "1"
    }
    #endif

    static func request(provider: String, operation: String, metadata: [String] = [], systemPrompt: String, userPrompt: String) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=request metadataCount=\(metadata.count) systemChars=\(systemPrompt.count) userChars=\(userPrompt.count)")
        #endif
    }

    static func response(provider: String, operation: String, text: String) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=response chars=\(text.count)")
        #endif
    }

    static func event(provider: String, operation: String, title: String, details: String) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=\(title) detailChars=\(details.count)")
        #endif
    }

    static func failure(provider: String, operation: String, error: Error) {
        #if DEBUG
        guard isEnabled else { return }
        print("[LLM] provider=\(provider) operation=\(operation) event=failure errorType=\(String(describing: type(of: error)))")
        #endif
    }
}

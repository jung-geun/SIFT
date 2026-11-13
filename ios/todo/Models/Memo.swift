import Foundation
import SwiftData

/// 자유 형식 메모. 회의·정리 중 raw 텍스트를 쌓아두고, 여기서 할 일 후보를 추출한다.
///
/// 추출 결과는 자동 등록되지 않는다. 사용자가 후보를 승인한 항목만 Todo가 된다.
/// CloudKit 동기화 대상: CloudModelCodec 명시 전송으로만 기기 간 공유.
@Model
final class Memo {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

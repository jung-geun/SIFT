import Foundation
import SwiftData

/// 사용자의 우선순위 가치관·생활 맥락.
///
/// IntelligenceService 프롬프트에 주입되어 개인화된 우선순위를 산출한다.
/// CloudKit 동기화 대상: 기기 간 동일한 페르소나 공유.
@Model
final class Persona {
    var id: UUID = UUID()

    /// 자연어로 기술된 사용자 가치관.
    /// 예: "업무 마감 > 가족 일정 > 개인 학습. 아침 9시 이전은 개인 시간."
    var descriptionText: String = ""

    /// PersonaType.rawValue 쉼표 구분 — 온보딩에서 다중 선택 가능 (CloudKit String 호환, 기본 "")
    /// 예: "student,freelancer"
    var personaTypeRaw: String = ""

    var updatedAt: Date = Date()

    /// 선택된 생활 유형 목록 (다중 선택)
    var personaTypes: [PersonaType] {
        get {
            personaTypeRaw
                .split(separator: ",")
                .compactMap { PersonaType(rawValue: String($0)) }
                .filter { $0 != .unspecified }
        }
        set { personaTypeRaw = newValue.map(\.rawValue).joined(separator: ",") }
    }

    /// 대표 유형 (첫 번째, 하위 호환용)
    var personaType: PersonaType { personaTypes.first ?? .unspecified }

    init(descriptionText: String = "", personaTypes: [PersonaType] = []) {
        self.descriptionText = descriptionText
        self.personaTypeRaw  = personaTypes.map(\.rawValue).joined(separator: ",")
    }
}

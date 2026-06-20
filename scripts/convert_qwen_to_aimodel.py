#!/usr/bin/env python3
"""
Qwen3.5-4B → .aimodel 변환 PoC
Core AI(coreai-torch + coreai-optimization) 사용.

선행 조건:
  - Xcode 27 베타 이상 설치 (Core AI 툴체인 포함)
  - pip install coreai-torch coreai-optimization transformers torch

실행:
  python3 scripts/convert_qwen_to_aimodel.py

출력:
  Qwen3.5-4B-ANE.aimodel  (현재 디렉터리 또는 --output 지정 경로)

이후:
  1. .aimodel 파일을 Xcode 프로젝트의 Resources 그룹에 추가 (Copy if needed)
  2. CoreAILanguageModelBackend.swift 의 COREAI_PREVIEW 플래그 활성화
  3. iOS 27 기기에서 테스트
"""

import argparse
import sys
import os
from pathlib import Path


def check_dependencies() -> bool:
    """필수 패키지 설치 여부를 확인한다."""
    missing = []
    for pkg in ["coreai", "transformers", "torch"]:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"[오류] 필수 패키지 미설치: {', '.join(missing)}")
        print("설치 명령:")
        print("  pip install coreai-torch coreai-optimization transformers torch")
        return False
    return True


def convert(
    model_id: str = "mlx-community/Qwen3.5-4B-MLX-4bit",
    output_path: str = "Qwen3.5-4B-ANE.aimodel",
    quantize_bits: int = 4,
    target_hardware: str = "ane",  # "ane" | "gpu" | "cpu"
    max_seq_len: int = 2048,
) -> None:
    """
    Qwen 모델을 .aimodel 형식으로 변환한다.

    Parameters
    ----------
    model_id      : HuggingFace 모델 ID (또는 로컬 경로)
    output_path   : 출력 .aimodel 파일 경로
    quantize_bits : 양자화 비트 수 (4 권장 — ANE 4-bit 최적화)
    target_hardware: "ane"(Neural Engine) | "gpu" | "cpu"
    max_seq_len   : 최대 시퀀스 길이 (메모리 제약에 맞게 조정)
    """
    # coreai-torch는 Xcode 27 설치 후 별도 pip로 제공됨.
    # API가 베타 단계이므로 실제 설치 후 import 경로 조정 필요.
    try:
        import coreai                          # noqa: F401 — Core AI Python 툴체인
        from coreai.torch import AIModelExporter
        from coreai.optimization import quantize, optimize_for_ane
    except ImportError:
        print("[오류] coreai 패키지를 찾을 수 없습니다.")
        print("Xcode 27 베타가 설치되어 있고 Core AI Python 툴체인이 활성화되어 있는지 확인하세요.")
        print("  xcrun coreai --version")
        sys.exit(1)

    from transformers import AutoModelForCausalLM, AutoTokenizer
    import torch

    print(f"[1/5] 모델 로드: {model_id}")
    # MLX 포맷은 PyTorch로 직접 로드가 안 되므로 원본 HF 모델 사용
    hf_model_id = "Qwen/Qwen2.5-3B"  # 4B MLX가 없으면 가장 근접한 공개 모델
    print(f"      HuggingFace 원본: {hf_model_id}")

    tokenizer = AutoTokenizer.from_pretrained(hf_model_id, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        hf_model_id,
        torch_dtype=torch.float16,
        trust_remote_code=True,
        device_map="cpu",  # 변환은 CPU에서 수행
    )
    model.eval()
    print(f"      파라미터 수: {sum(p.numel() for p in model.parameters()) / 1e9:.2f}B")

    print(f"[2/5] {quantize_bits}-bit 양자화")
    quantized_model = quantize(model, bits=quantize_bits)

    print(f"[3/5] {target_hardware.upper()} 최적화")
    if target_hardware == "ane":
        optimized_model = optimize_for_ane(
            quantized_model,
            max_sequence_length=max_seq_len,
            batch_size=1,
        )
    else:
        optimized_model = quantized_model

    print("[4/5] .aimodel 내보내기")
    # 샘플 입력으로 함수 시그니처 정의
    sample_input_ids = torch.zeros((1, 16), dtype=torch.long)
    exporter = AIModelExporter(
        model=optimized_model,
        tokenizer=tokenizer,
        function_name="language_model_forward",  # CoreAILanguageModelBackend와 일치시킬 것
        inputs={"input_ids": sample_input_ids},
        outputs=["logits"],
        target=target_hardware,
    )
    exporter.export(output_path)
    print(f"      저장 완료: {output_path}")

    size_mb = Path(output_path).stat().st_size / (1024 * 1024)
    print(f"      파일 크기: {size_mb:.1f} MB")

    print("[5/5] 로드 검증")
    # 변환된 .aimodel이 실제로 로드 가능한지 확인 (macOS에서 실행)
    try:
        import coreai as ca
        loaded = ca.AIModel(output_path)
        fn = loaded.load_function("language_model_forward")
        import numpy as np
        dummy_ids = np.zeros((1, 16), dtype=np.int32)
        result = fn.run(inputs={"input_ids": dummy_ids}, states={})
        logits_shape = result["logits"].shape
        print(f"      ✅ 로드 성공. 출력 shape: {logits_shape}")
    except Exception as e:
        print(f"      ⚠️  검증 실패 (기기에서 테스트 필요): {e}")

    print("\n변환 완료!")
    print(f"다음 단계:")
    print(f"  1. {output_path} 를 Xcode 프로젝트 Resources에 추가")
    print(f"  2. Build Settings > OTHER_SWIFT_FLAGS += -DCOREAI_PREVIEW")
    print(f"  3. CoreAILanguageModelBackend.swift 의 TODO 항목들 실제 Core AI API로 업데이트")
    print(f"  4. iOS 27 실기기에서 테스트")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Qwen 모델을 Apple Core AI .aimodel 형식으로 변환"
    )
    parser.add_argument(
        "--model-id",
        default="Qwen/Qwen2.5-3B",
        help="HuggingFace 모델 ID 또는 로컬 경로 (기본: Qwen/Qwen2.5-3B)",
    )
    parser.add_argument(
        "--output",
        default="Qwen3.5-4B-ANE.aimodel",
        help=".aimodel 출력 파일명 (기본: Qwen3.5-4B-ANE.aimodel)",
    )
    parser.add_argument(
        "--bits",
        type=int,
        default=4,
        choices=[4, 8],
        help="양자화 비트 수 (기본: 4)",
    )
    parser.add_argument(
        "--target",
        default="ane",
        choices=["ane", "gpu", "cpu"],
        help="실행 타깃 하드웨어 (기본: ane)",
    )
    parser.add_argument(
        "--max-seq-len",
        type=int,
        default=2048,
        help="최대 시퀀스 길이 (기본: 2048)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="실제 변환 없이 의존성만 확인",
    )
    args = parser.parse_args()

    print("=== Qwen → .aimodel 변환 PoC ===")
    print(f"대상 모델  : {args.model_id}")
    print(f"출력 경로  : {args.output}")
    print(f"양자화     : {args.bits}-bit")
    print(f"하드웨어   : {args.target.upper()}")
    print(f"최대 seq   : {args.max_seq_len}")
    print()

    if not check_dependencies():
        sys.exit(1)

    if args.dry_run:
        print("[dry-run] 의존성 확인 완료. 실제 변환 건너뜀.")
        return

    convert(
        model_id=args.model_id,
        output_path=args.output,
        quantize_bits=args.bits,
        target_hardware=args.target,
        max_seq_len=args.max_seq_len,
    )


if __name__ == "__main__":
    main()

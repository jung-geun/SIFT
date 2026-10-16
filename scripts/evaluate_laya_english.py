#!/usr/bin/env python3
"""Evaluate English Laya on original EN and machine-translated KO priority fixtures.

Offline inference; initial checkpoint download needs network. Translator is a Korean-only
research comparator, NOT a translation implementation for arbitrary app languages.
"""

import argparse
import json
from pathlib import Path

from evaluate_laya_priority import (
    FIXTURES, MIN_ACCURACY, MIN_CLASS_RECALL, questions, summarize, validate,
)

DECISION_MODEL = "convaiinnovations/laya"
DECISION_REVISION = "55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851"
TRANSLATION_MODEL = "Helsinki-NLP/opus-mt-ko-en"
TRANSLATION_REVISION = "e42d1f41b66194e6d10512f8a27bebc1f4f5097e"
FIELDS = ("title", "details", "due")


def translate_korean(cases, batch_size):
    import torch
    from huggingface_hub import snapshot_download
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    source = snapshot_download(
        TRANSLATION_MODEL, revision=TRANSLATION_REVISION,
        allow_patterns=["config.json", "generation_config.json", "pytorch_model.bin", "source.spm", "target.spm", "tokenizer_config.json", "vocab.json"],
    )
    tokenizer = AutoTokenizer.from_pretrained(source)
    model = AutoModelForSeq2SeqLM.from_pretrained(source, use_safetensors=False).to("mps").eval()
    texts = [row["state"][field] for row in cases for field in FIELDS]
    translations = []
    with torch.inference_mode():
        for offset in range(0, len(texts), batch_size):
            batch = tokenizer(texts[offset:offset + batch_size], return_tensors="pt", padding=True, truncation=True)
            generated = model.generate(**{key: value.to("mps") for key, value in batch.items()}, max_new_tokens=128)
            translations.extend(tokenizer.batch_decode(generated, skip_special_tokens=True))
    return [dict(zip(FIELDS, translations[index:index + len(FIELDS)], strict=True))
            for index in range(0, len(translations), len(FIELDS))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/tmp/sift-laya-english-evaluation.json"))
    parser.add_argument("--batch-size", type=int, default=4)
    args = parser.parse_args()
    if args.batch_size < 1:
        parser.error("--batch-size must be positive")

    from huggingface_hub import snapshot_download
    from laya import Agent

    cases = json.loads(FIXTURES.read_text(encoding="utf-8"))["cases"]
    validate(cases)
    korean = [row for row in cases if row["locale"] == "ko"]
    english_states = translate_korean(korean, args.batch_size)
    snapshot = snapshot_download(
        DECISION_MODEL, revision=DECISION_REVISION,
        allow_patterns=["rl_agent_config.json", "model.safetensors", "tokenizer/*", "encoder/*"],
    )
    agent = Agent(snapshot, device="mps")
    predictions = []
    translated_states = {}
    for locale in ("en", "ko"):
        subset = [row for row in cases if row["locale"] == locale]
        states = [row["state"] for row in subset] if locale == "en" else english_states
        if locale == "ko":
            translated_states = {row["id"]: state for row, state in zip(subset, states, strict=True)}
        results = agent.predict_batch(states, questions("en"), batch_size=args.batch_size, lang="en")
        for row, answer in zip(subset, results, strict=True):
            decision = answer["answers"]["priority"]
            predictions.append({"id": row["id"], "locale": locale, "expected": row["label"],
                                "actual": decision["choice"], "probabilities": decision["probabilities"],
                                "correct": decision["choice"] == row["label"]})
    metrics = summarize(predictions)
    passed = all(
        row["accuracy"] >= MIN_ACCURACY and all(recall >= MIN_CLASS_RECALL for recall in row["recall"].values())
        for row in metrics.values()
    )
    report = {"decision_model": DECISION_MODEL, "decision_revision": DECISION_REVISION,
              "translation_model": TRANSLATION_MODEL, "translation_revision": TRANSLATION_REVISION,
              "gate": {"accuracy_per_locale": MIN_ACCURACY, "recall_per_class": MIN_CLASS_RECALL},
              "metrics": metrics, "passed": passed, "translated_states": translated_states,
              "predictions": predictions}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key not in ("predictions", "translated_states")}, indent=2))
    print(f"Full predictions and translations: {args.output}")
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
